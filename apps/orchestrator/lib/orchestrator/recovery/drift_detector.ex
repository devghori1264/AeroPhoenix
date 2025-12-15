defmodule Orchestrator.Recovery.DriftDetector do
  require Logger

  alias Orchestrator.MachineActor.Storage

  @type machine_id :: String.t()
  @type anomaly_type :: :ghost | :zombie | :state_drift
  @type severity :: :low | :medium | :high | :critical

  @type ghost :: %{
          type: :ghost,
          severity: :high,
          machine_id: machine_id(),
          pid: pid(),
          registered_at: DateTime.t() | nil,
          reason: :process_dead | :supervisor_restart_failed
        }

  @type zombie :: %{
          type: :zombie,
          severity: :critical,
          machine_id: machine_id(),
          db_state: atom(),
          db_path: String.t(),
          last_transition_at: DateTime.t() | nil,
          reason: :node_crash | :oom_kill | :supervisor_gave_up | :manual_kill
        }

  @type state_drift :: %{
          type: :state_drift,
          severity: :medium,
          machine_id: machine_id(),
          pid: pid(),
          db_state: atom(),
          process_state: atom(),
          mismatch_detected_at: DateTime.t(),
          reason: :partial_transaction | :clock_skew | :wal_corruption
        }

  @type anomaly :: ghost() | zombie() | state_drift()

  @type drift_report :: %{
          timestamp: DateTime.t(),
          scan_duration_ms: non_neg_integer(),
          total_machines: non_neg_integer(),
          anomalies: [anomaly()],
          summary: %{
            ghosts: non_neg_integer(),
            zombies: non_neg_integer(),
            drifts: non_neg_integer(),
            healthy: non_neg_integer()
          },
          node: node(),
          region: String.t()
        }
  @spec detect_drift(keyword()) :: {:ok, drift_report()} | {:error, term()}
  def detect_drift(opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    timeout = Keyword.get(opts, :timeout, 5_000)
    skip_state_check = Keyword.get(opts, :skip_state_check, false)
    parallel = Keyword.get(opts, :parallel, false)

    data_dir =
      Keyword.get(
        opts,
        :data_dir,
        Application.get_env(:orchestrator, :machine_actor_data_dir, "data/machines")
      )

    Logger.info("Starting drift detection scan",
      node: node(),
      timeout: timeout,
      skip_state_check: skip_state_check,
      data_dir: data_dir
    )

    try do
      all_processes = Process.list()

      Logger.debug("BEAM process scan complete",
        total_processes: length(all_processes)
      )

      registry_entries = get_registry_entries()

      Logger.debug("Registry scan complete",
        registered_machines: length(registry_entries)
      )

      db_machines = get_database_machines(data_dir)

      Logger.debug("Database scan complete",
        db_active_machines: length(db_machines)
      )

      anomalies =
        if parallel do
          detect_anomalies_parallel(
            all_processes,
            registry_entries,
            db_machines,
            timeout,
            skip_state_check
          )
        else
          detect_anomalies_sequential(
            all_processes,
            registry_entries,
            db_machines,
            timeout,
            skip_state_check
          )
        end

      scan_duration_ms = System.monotonic_time(:millisecond) - start_time
      total_machines = length(db_machines)

      summary = %{
        ghosts: Enum.count(anomalies, &(&1.type == :ghost)),
        zombies: Enum.count(anomalies, &(&1.type == :zombie)),
        drifts: Enum.count(anomalies, &(&1.type == :state_drift)),
        healthy: total_machines - length(anomalies)
      }

      report = %{
        timestamp: DateTime.utc_now(),
        scan_duration_ms: scan_duration_ms,
        total_machines: total_machines,
        anomalies: anomalies,
        summary: summary,
        node: node(),
        region: get_node_region()
      }

      Logger.info("Drift detection scan complete",
        duration_ms: scan_duration_ms,
        summary: summary
      )

      :telemetry.execute(
        [:orchestrator, :drift_detection, :scan_complete],
        %{
          duration_ms: scan_duration_ms,
          total_machines: total_machines,
          anomaly_count: length(anomalies)
        },
        %{node: node(), region: get_node_region()}
      )

      Enum.each(anomalies, fn anomaly ->
        :telemetry.execute(
          [:orchestrator, :drift_detection, :anomaly_found],
          %{count: 1},
          %{
            type: anomaly.type,
            machine_id: anomaly.machine_id,
            severity: anomaly.severity
          }
        )
      end)

      {:ok, report}
    rescue
      e ->
        Logger.error("Drift detection failed",
          error: inspect(e),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        {:error, {:drift_detection_failed, e}}
    end
  end

  @spec check_machine(machine_id(), keyword()) ::
          {:ok, :healthy}
          | {:ok, {:anomaly, anomaly()}}
          | {:error, :not_found | term()}
  def check_machine(machine_id, opts \\ []) when is_binary(machine_id) do
    data_dir =
      Keyword.get(
        opts,
        :data_dir,
        Application.get_env(:orchestrator, :machine_actor_data_dir, "data/machines")
      )

    db_path = get_db_path(machine_id, data_dir)

    unless File.exists?(db_path) do
      {:error, :not_found}
    else
      registry_pid = get_registry_pid(machine_id)

      {:ok, db_state} = get_db_state(machine_id, data_dir)

      perform_drift_check(machine_id, registry_pid, db_state, db_path)
    end
  end

  defp get_database_machines(data_dir) do
    case File.ls(data_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".db"))
        |> Enum.map(fn filename ->
          machine_id = String.replace_suffix(filename, ".db", "")
          db_path = Path.join(data_dir, filename)

          case get_db_state(machine_id, data_dir) do
            {:ok, state} ->
              %{
                machine_id: machine_id,
                db_path: db_path,
                state: state
              }

            {:error, _reason} ->
              %{
                machine_id: machine_id,
                db_path: db_path,
                state: :unknown
              }
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error("Failed to scan machine data directory",
          reason: inspect(reason)
        )

        []
    end
  end

  defp get_db_state(machine_id, data_dir) do
    db_path = get_db_path(machine_id, data_dir)

    case Storage.init(db_path) do
      {:ok, conn} ->
        try do
          case Storage.load_metadata(conn) do
            {:ok, meta} ->
              {:ok, meta.state}

            {:error, :not_found} ->
              {:ok, :created}

            {:error, reason} ->
              {:error, reason}
          end
        after
          Storage.close(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_db_path(machine_id, data_dir) do
    Path.join(data_dir, "#{machine_id}.db")
  end

  defp perform_drift_check(machine_id, registry_pid, db_state, db_path) do
    cond do
      registry_pid != nil && !Process.alive?(registry_pid) ->
        anomaly = %{
          type: :ghost,
          severity: :high,
          machine_id: machine_id,
          pid: registry_pid,
          registered_at: nil,
          reason: :process_dead
        }

        {:ok, {:anomaly, anomaly}}

      db_state in [:running, :starting, :created] && registry_pid == nil ->
        anomaly = %{
          type: :zombie,
          severity: :critical,
          machine_id: machine_id,
          db_state: db_state,
          db_path: db_path,
          last_transition_at: nil,
          reason: :supervisor_gave_up
        }

        {:ok, {:anomaly, anomaly}}

      registry_pid != nil && Process.alive?(registry_pid) ->
        case get_process_state(registry_pid, 5_000) do
          {:ok, process_state} when process_state != db_state ->
            anomaly = %{
              type: :state_drift,
              severity: :medium,
              machine_id: machine_id,
              pid: registry_pid,
              db_state: db_state,
              process_state: process_state,
              mismatch_detected_at: DateTime.utc_now(),
              reason: :partial_transaction
            }

            {:ok, {:anomaly, anomaly}}

          {:ok, _process_state} ->
            {:ok, :healthy}

          {:error, _reason} ->
            {:ok, :healthy}
        end

      true ->
        {:ok, :healthy}
    end
  end

  defp get_registry_entries do
    Registry.select(Orchestrator.MachineActorRegistry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  defp get_registry_pid(machine_id) do
    case Registry.lookup(Orchestrator.MachineActorRegistry, machine_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp get_process_state(pid, timeout) do
    try do
      case GenServer.call(pid, :get_state, timeout) do
        %{current_state: state} -> {:ok, state}
        state when is_atom(state) -> {:ok, state}
        _ -> {:error, :invalid_state_format}
      end
    catch
      :exit, {:timeout, _} ->
        {:error, :timeout}

      :exit, reason ->
        {:error, {:process_exit, reason}}
    end
  end

  defp detect_anomalies_sequential(
         all_processes,
         registry_entries,
         db_machines,
         timeout,
         skip_state_check
       ) do
    ghosts = detect_ghosts(registry_entries, all_processes)
    zombies = detect_zombies(db_machines, registry_entries)

    drifts =
      if skip_state_check do
        []
      else
        detect_state_drift(registry_entries, db_machines, timeout)
      end

    ghosts ++ zombies ++ drifts
  end

  defp detect_anomalies_parallel(
         all_processes,
         registry_entries,
         db_machines,
         timeout,
         skip_state_check
       ) do
    tasks = [
      Task.async(fn -> detect_ghosts(registry_entries, all_processes) end),
      Task.async(fn -> detect_zombies(db_machines, registry_entries) end)
    ]

    tasks =
      if skip_state_check do
        tasks
      else
        [
          Task.async(fn ->
            detect_state_drift(registry_entries, db_machines, timeout)
          end)
          | tasks
        ]
      end

    results =
      Task.yield_many(tasks, timeout + 1_000)
      |> Enum.map(fn {task, result} ->
        case result do
          {:ok, []} ->
            []

          {:ok, anomalies} ->
            anomalies

          {:exit, _reason} ->
            []

          nil ->
            case Task.shutdown(task, :brutal_kill) do
              {:ok, res} -> res
              _ -> []
            end
        end
      end)
      |> List.flatten()

    results
  end

  defp detect_ghosts(registry_entries, all_processes) do
    process_set = MapSet.new(all_processes)

    Enum.reduce(registry_entries, [], fn {machine_id, pid}, acc ->
      if MapSet.member?(process_set, pid) do
        acc
      else
        ghost = %{
          type: :ghost,
          severity: :high,
          machine_id: machine_id,
          pid: pid,
          registered_at: nil,
          reason: :process_dead
        }

        [ghost | acc]
      end
    end)
  end

  defp detect_zombies(db_machines, registry_entries) do
    registry_map = Map.new(registry_entries, fn {id, pid} -> {id, pid} end)

    Enum.reduce(db_machines, [], fn machine, acc ->
      if machine.state in [:running, :starting, :created] do
        case Map.get(registry_map, machine.machine_id) do
          nil ->
            zombie = %{
              type: :zombie,
              severity: :critical,
              machine_id: machine.machine_id,
              db_state: machine.state,
              db_path: machine.db_path,
              last_transition_at: nil,
              reason: :supervisor_gave_up
            }

            [zombie | acc]

          _pid ->
            acc
        end
      else
        acc
      end
    end)
  end

  defp detect_state_drift(registry_entries, db_machines, timeout) do
    db_state_map =
      Map.new(db_machines, fn m -> {m.machine_id, m.state} end)

    Enum.reduce(registry_entries, [], fn {machine_id, pid}, acc ->
      db_state = Map.get(db_state_map, machine_id)

      if db_state != nil do
        case get_process_state(pid, timeout) do
          {:ok, process_state} when process_state != db_state ->
            drift = %{
              type: :state_drift,
              severity: :medium,
              machine_id: machine_id,
              pid: pid,
              db_state: db_state,
              process_state: process_state,
              mismatch_detected_at: DateTime.utc_now(),
              reason: :partial_transaction
            }

            [drift | acc]

          {:ok, _process_state} ->
            acc

          {:error, reason} ->
            Logger.debug("Failed to get process state for drift check",
              machine_id: machine_id,
              pid: inspect(pid),
              reason: inspect(reason)
            )

            acc
        end
      else
        acc
      end
    end)
  end

  defp get_node_region do
    node_name = Atom.to_string(node())

    case String.split(node_name, "@") do
      [_app, region] -> region
      _ -> "unknown"
    end
  end
end
