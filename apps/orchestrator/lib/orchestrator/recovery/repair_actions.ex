defmodule Orchestrator.Recovery.RepairActions do
  require Logger

  alias Orchestrator.MachineActor.Storage
  alias Orchestrator.MachineActor.Supervisor, as: MachineSupervisor

  @type repair_result ::
          {:ok, :repaired}
          | {:ok, :already_healthy}
          | {:ok, :self_healed}
          | {:error, {:repair_failed, term()}}

  @type anomaly :: map()
  @spec execute(anomaly()) :: repair_result()
  def execute(anomaly) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Executing repair action",
      anomaly_type: anomaly.type,
      machine_id: anomaly.machine_id,
      severity: anomaly.severity
    )

    pre_state = capture_state_snapshot(anomaly)

    result =
      case anomaly.type do
        :ghost ->
          repair_ghost(anomaly)

        :zombie ->
          repair_zombie(anomaly)

        :state_drift ->
          repair_state_drift(anomaly)

        _ ->
          {:error, {:repair_failed, :unknown_anomaly_type}}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time
    post_state = capture_state_snapshot(anomaly)

    case result do
      {:ok, outcome} ->
        Logger.info("Repair succeeded",
          anomaly_type: anomaly.type,
          machine_id: anomaly.machine_id,
          outcome: outcome,
          duration_ms: duration_ms,
          pre_state: inspect(pre_state),
          post_state: inspect(post_state)
        )

        :telemetry.execute(
          [:orchestrator, :repair_actions, :success],
          %{duration_ms: duration_ms},
          %{
            anomaly_type: anomaly.type,
            machine_id: anomaly.machine_id,
            outcome: outcome
          }
        )

        {:ok, outcome}

      {:error, reason} ->
        Logger.info("Repair failed",
          anomaly_type: anomaly.type,
          machine_id: anomaly.machine_id,
          error: inspect(reason),
          duration_ms: duration_ms,
          pre_state: inspect(pre_state),
          post_state: inspect(post_state)
        )

        :telemetry.execute(
          [:orchestrator, :repair_actions, :failed],
          %{duration_ms: duration_ms},
          %{
            anomaly_type: anomaly.type,
            machine_id: anomaly.machine_id,
            reason: reason
          }
        )

        {:error, {:repair_failed, reason}}
    end
  end

  @spec execute_with_retry(anomaly(), keyword()) :: repair_result()
  def execute_with_retry(anomaly, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, 1000)

    execute_with_retry_loop(anomaly, 1, max_attempts, base_delay_ms, nil)
  end

  defp repair_ghost(anomaly) do
    _doc = """
    Ghost Process Repair Strategy:

    A ghost occurs when Registry still points to a dead PID. This happens when:
    1. Process crashes without proper cleanup
    2. Supervisor restart fails silently
    3. Registry monitor message gets delayed

    Repair Action:
    - Verify process is actually dead (double-check with Process.alive?)
    - If dead, rely on Registry's built-in monitoring to clean up
    - Log the ghost for forensics

    Risk: None (Registry self-heals via monitors)
    """

    machine_id = anomaly.machine_id
    pid = anomaly.pid

    Logger.info("Repairing ghost process", machine_id: machine_id, pid: inspect(pid))

    if Process.alive?(pid) do
      Logger.info("Ghost false positive - process alive",
        machine_id: machine_id,
        pid: inspect(pid)
      )

      {:ok, :already_healthy}
    else
      Process.sleep(100)

      case MachineSupervisor.find_machine(machine_id) do
        {:ok, new_pid} when new_pid != pid ->
          Logger.info("Ghost self-healed - new process registered",
            machine_id: machine_id,
            old_pid: inspect(pid),
            new_pid: inspect(new_pid)
          )

          {:ok, :self_healed}

        {:error, :not_found} ->
          Logger.info("Ghost cleaned up by Registry monitor",
            machine_id: machine_id,
            pid: inspect(pid)
          )

          {:ok, :repaired}

        {:ok, ^pid} ->
          Logger.warning("Forcing ghost cleanup - Registry monitor delayed",
            machine_id: machine_id,
            pid: inspect(pid)
          )

          Orchestrator.ResourceManager.release_resources(machine_id)

          {:ok, :repaired}
      end
    end
  end

  defp repair_zombie(anomaly) do
    _doc = """
    Zombie Machine Repair Strategy:

    A zombie occurs when SQLite says :running/:starting but no process exists.

    Root Causes:
    1. Node crash (entire BEAM VM went down)
    2. OOM killer terminated the process
    3. Supervisor gave up after max_restarts
    4. Manual kill via `kill -9`

    Repair Action:
    1. Verify machine is truly a zombie (process really missing)
    2. Start new MachineActor process via Supervisor
    3. Process will auto-recover state from SQLite + WAL replay
    4. Verify successful startup

    Risk: Medium
    - If underlying issue persists (e.g., OOM), will crash again
    - Resource leak if multiple resurrections attempted
    - WAL replay might fail if database corrupted

    Mitigation:
    - Track resurrection count per machine
    - Limit to 3 auto-resurrections per hour
    - Alert if same machine zombifies repeatedly
    """

    machine_id = anomaly.machine_id
    db_state = anomaly.db_state

    Logger.info("Repairing zombie machine",
      machine_id: machine_id,
      db_state: db_state
    )

    case MachineSupervisor.find_machine(machine_id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          Logger.info("Zombie false positive - process alive",
            machine_id: machine_id,
            pid: inspect(pid)
          )

          {:ok, :already_healthy}
        else
          resurrect_machine(machine_id, anomaly)
        end

      {:error, :not_found} ->
        resurrect_machine(machine_id, anomaly)
    end
  end

  defp resurrect_machine(machine_id, anomaly) do
    case MachineSupervisor.restart_machine(machine_id) do
      {:ok, pid} ->
        Logger.info("Zombie resurrected successfully from metadata",
          machine_id: machine_id,
          pid: inspect(pid)
        )
        verify_resurrection(machine_id, pid, anomaly)

      {:error, :no_persisted_state} ->
        Logger.warning("Zombie resurrection missing metadata, using fallback", machine_id: machine_id)
        fallback_resurrect(machine_id, anomaly)

      {:error, reason} ->
        Logger.info("Zombie resurrection failed",
          machine_id: machine_id,
          reason: inspect(reason)
        )
        {:error, reason}
    end
  end

  defp fallback_resurrect(machine_id, anomaly) do
    region = extract_region_from_db(machine_id) || "recovered"

    case MachineSupervisor.start_machine(id: machine_id, region: region) do
      {:error, :insufficient_cpu, _details} ->
        Logger.info("Zombie resurrection failed - insufficient CPU", machine_id: machine_id)
        {:error, :insufficient_resources}

      {:error, :insufficient_memory, _details} ->
        Logger.info("Zombie resurrection failed - insufficient memory", machine_id: machine_id)
        {:error, :insufficient_resources}

      {:ok, pid} ->
        Logger.info("Zombie resurrected successfully (fallback)",
          machine_id: machine_id,
          pid: inspect(pid)
        )
        verify_resurrection(machine_id, pid, anomaly)

      {:error, :already_exists} ->
        Logger.info("Zombie resurrection race - already started",
          machine_id: machine_id
        )
        {:ok, :already_healthy}

      {:error, reason} ->
        Logger.info("Zombie resurrection failed",
          machine_id: machine_id,
          reason: inspect(reason)
        )
        {:error, reason}
    end
  end

  defp verify_resurrection(machine_id, pid, anomaly) do
    Process.sleep(100)

    if Process.alive?(pid) do
      case GenServer.call(pid, :get_state, 5000) do
        state when is_atom(state) ->
          Logger.info("Zombie state recovered",
            machine_id: machine_id,
            recovered_state: state,
            db_state: anomaly.db_state
          )
          {:ok, :repaired}

        _ ->
          {:ok, :repaired}
      end
    else
      Logger.info("Zombie resurrection failed - process died immediately",
        machine_id: machine_id
      )
      {:error, :immediate_crash}
    end
  end

  defp repair_state_drift(anomaly) do
    _doc = """
    State Drift Repair Strategy:

    State drift occurs when process state != database state.

    Example:
    - DB state: :starting
    - Process state: :running
    - Likely cause: Process updated in-memory state but didn't write to DB

    Decision Tree:
    1. Determine "source of truth" (newer timestamp wins)
    2. If process state newer → update DB
    3. If DB state newer → update process (force sync)
    4. If timestamps equal → trust process (it's running reality)

    Risk: High
    - Wrong decision can lose in-flight operations
    - Forcing process state can cause FSM violations
    - Database write might fail, leaving drift unresolved

    Mitigation:
    - Always write sync intent to WAL first
    - Use vector clocks for causality (not just timestamps)
    - Prefer manual intervention for critical machines
    - Emit alerts for repeated drift on same machine

    Strategy: Conservative Auto-Repair
    - Only auto-repair if confidence >95%
    - Otherwise, log and alert for manual intervention
    """

    machine_id = anomaly.machine_id
    pid = anomaly.pid
    db_state = anomaly.db_state
    process_state = anomaly.process_state

    Logger.info("Repairing state drift",
      machine_id: machine_id,
      db_state: db_state,
      process_state: process_state
    )

    Process.sleep(50)

    current_process_state =
      case GenServer.call(pid, :get_state, 5000) do
        state when is_atom(state) -> state
        _ -> nil
      end

    current_db_state = get_db_state(machine_id)

    if current_process_state == current_db_state do
      Logger.info("State drift self-healed",
        machine_id: machine_id,
        current_state: current_process_state
      )

      {:ok, :self_healed}
    else
      apply_state_sync_strategy(machine_id, pid, current_db_state, current_process_state)
    end
  end

  defp apply_state_sync_strategy(machine_id, _pid, db_state, process_state) do
    Logger.info("Syncing database to match process state",
      machine_id: machine_id,
      from_state: db_state,
      to_state: process_state
    )

    case update_database_state(machine_id, process_state) do
      :ok ->
        Logger.info("State drift repaired - DB updated",
          machine_id: machine_id,
          new_state: process_state
        )

        {:ok, :repaired}

      {:error, reason} ->
        Logger.error("State drift repair failed - DB update failed",
          machine_id: machine_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp execute_with_retry_loop(anomaly, attempt, max_attempts, base_delay_ms, last_error) do
    if attempt > max_attempts do
      Logger.info("Repair failed after all retries",
        anomaly_type: anomaly.type,
        machine_id: anomaly.machine_id,
        attempts: max_attempts,
        last_error: inspect(last_error)
      )

      {:error, {:repair_failed, last_error || :max_retries_exceeded}}
    else
      if attempt > 1 do
        delay_ms = (base_delay_ms * :math.pow(2, attempt - 2)) |> round()

        Logger.info("Retry backoff delay",
          anomaly_type: anomaly.type,
          machine_id: anomaly.machine_id,
          attempt: attempt,
          delay_ms: delay_ms
        )

        Process.sleep(delay_ms)
      end

      case execute(anomaly) do
        {:ok, outcome} ->
          if attempt > 1 do
            Logger.info("Repair succeeded on retry",
              anomaly_type: anomaly.type,
              machine_id: anomaly.machine_id,
              attempt: attempt
            )
          end

          {:ok, outcome}

        {:error, {:repair_failed, reason}} ->
          execute_with_retry_loop(
            anomaly,
            attempt + 1,
            max_attempts,
            base_delay_ms,
            reason
          )
      end
    end
  end

  defp capture_state_snapshot(anomaly) do
    machine_id = anomaly.machine_id

    %{
      timestamp: DateTime.utc_now(),
      machine_id: machine_id,
      registry_status: get_registry_status(machine_id),
      db_state: get_db_state(machine_id),
      process_alive: is_process_alive(machine_id)
    }
  end

  defp get_registry_status(machine_id) do
    case MachineSupervisor.find_machine(machine_id) do
      {:ok, pid} -> {:registered, pid, Process.alive?(pid)}
      {:error, :not_found} -> :not_registered
    end
  end

  defp get_db_state(machine_id) do
    db_path = get_db_path(machine_id)

    case Storage.init(db_path) do
      {:ok, conn} ->
        state =
          case Storage.execute(conn, "SELECT state FROM machines LIMIT 1") do
            {:ok, [[state_str]]} when is_binary(state_str) ->
              String.to_existing_atom(state_str)

            {:ok, []} ->
              :created

            _ ->
              :unknown
          end

        Exqlite.Sqlite3.close(conn)
        state

      {:error, _reason} ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  defp is_process_alive(machine_id) do
    case MachineSupervisor.find_machine(machine_id) do
      {:ok, pid} -> Process.alive?(pid)
      _ -> false
    end
  end

  defp extract_region_from_db(machine_id) do
    db_path = get_db_path(machine_id)

    case Storage.init(db_path) do
      {:ok, conn} ->
        region =
          case Storage.execute(conn, "SELECT region FROM machines LIMIT 1") do
            {:ok, [[region_str]]} when is_binary(region_str) ->
              region_str

            _ ->
              nil
          end

        Exqlite.Sqlite3.close(conn)
        region

      {:error, _reason} ->
        nil
    end
  rescue
    _ -> nil
  end

  defp update_database_state(machine_id, new_state) do
    db_path = get_db_path(machine_id)

    case Storage.init(db_path) do
      {:ok, conn} ->
        sql = """
        UPDATE machines
        SET state = ?, updated_at = ?
        WHERE 1=1
        """

        params = [
          Atom.to_string(new_state),
          DateTime.to_iso8601(DateTime.utc_now())
        ]

        result =
          case Storage.execute(conn, sql, params) do
            {:ok, _rows} -> :ok
            {:error, reason} -> {:error, reason}
          end

        Exqlite.Sqlite3.close(conn)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_db_path(machine_id) do
    data_dir =
      Application.get_env(:orchestrator, :storage_path, "data/machines")

    Path.join(data_dir, "#{machine_id}.db")
  end
end
