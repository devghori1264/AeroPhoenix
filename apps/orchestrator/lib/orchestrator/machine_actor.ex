defmodule Orchestrator.MachineActor do
  use GenServer
  require Logger

  alias Orchestrator.MachineActor.{WAL, FSM, Storage}

  @type machine_id :: String.t()
  @type operation_id :: String.t()
  @type state :: FSM.state()
  @type transition_result ::
          {:ok, %{from: state(), to: state(), timestamp: DateTime.t()}}
          | {:error, FSM.transition_error()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(id))
  end

  @spec transition(GenServer.server(), atom(), keyword()) :: transition_result()
  def transition(server, transition_type, opts \\ []) do
    GenServer.call(server, {:transition, transition_type, opts}, :infinity)
  end

  @spec get_state(GenServer.server()) :: {:ok, map()}
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @spec get_history(GenServer.server(), keyword()) :: {:ok, [map()]}
  def get_history(server, opts \\ []) do
    GenServer.call(server, {:get_history, opts})
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    start_link(opts)
  end

  @spec health_check(GenServer.server()) ::
          {:ok, :healthy | :degraded} | {:error, :timeout | :not_found}
  def health_check(server) do
    timeout = 5_000
    start_time = System.monotonic_time(:millisecond)

    try do
      case GenServer.call(server, :health_check, timeout) do
        :ok ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          if elapsed > 1_000 do
            {:ok, :degraded}
          else
            {:ok, :healthy}
          end
      end
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, {:noproc, _} -> {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    region = Keyword.fetch!(opts, :region)

    data_dir = Application.get_env(:orchestrator, :machine_actor_data_dir, "data/machines")
    File.mkdir_p!(data_dir)

    db_path = Path.join(data_dir, "#{id}.db")

    case Storage.init(db_path) do
      {:ok, conn} ->
        metadata =
          case Storage.load_metadata(conn) do
            {:ok, meta} ->
              Logger.info("MachineActor[#{id}] recovered from disk",
                region: meta.region,
                state: meta.state
              )

              meta

            {:error, :not_found} ->
              initial_meta = %{
                id: id,
                region: region,
                state: :created,
                image: Keyword.get(opts, :image),
                size: Keyword.get(opts, :size, %{cpu_count: 1, memory_mb: 256}),
                capabilities: Keyword.get(opts, :capabilities, [:start, :stop, :migrate]),
                created_at: DateTime.utc_now(),
                updated_at: DateTime.utc_now(),
                version: 1
              }

              :ok = Storage.save_metadata(conn, initial_meta)
              Logger.info("MachineActor[#{id}] created", region: region)
              initial_meta
          end

        case WAL.replay(conn, metadata.state) do
          {:ok, recovered_state, pending_operations} ->
            Logger.info("MachineActor[#{id}] WAL replay complete",
              final_state: recovered_state,
              pending_ops: length(pending_operations)
            )

            case WAL.replay_uncommitted_intents(conn, current_state: recovered_state) do
              {:ok, replay_result} ->
                if replay_result.completed != [] ||
                     replay_result.rolled_back != [] ||
                     replay_result.conflicts != [] do
                  Logger.info("MachineActor[#{id}] uncommitted intent replay complete",
                    completed: length(replay_result.completed),
                    rolled_back: length(replay_result.rolled_back),
                    conflicts: length(replay_result.conflicts)
                  )

                  :telemetry.execute(
                    [:machine_actor, :crash_recovery, :complete],
                    %{
                      completed_count: length(replay_result.completed),
                      rolled_back_count: length(replay_result.rolled_back),
                      conflict_count: length(replay_result.conflicts)
                    },
                    %{id: id}
                  )
                end

              {:error, reason} ->
                Logger.error("MachineActor[#{id}] uncommitted intent replay failed",
                  reason: inspect(reason)
                )
            end

            if length(pending_operations) > 0 do
              send(self(), {:reconcile_pending, pending_operations})
            end

            state = %{
              id: id,
              conn: conn,
              db_path: db_path,
              metadata: %{metadata | state: recovered_state},
              operation_lock: nil,
              pending_transitions: :queue.new(),
              stats: %{
                transitions: 0,
                errors: 0,
                avg_transition_ms: 0.0
              }
            }

            :telemetry.execute(
              [:machine_actor, :started],
              %{count: 1},
              %{id: id, region: region, state: recovered_state}
            )

            {:ok, state}

          {:error, reason} ->
            Logger.error("MachineActor[#{id}] WAL replay failed", reason: inspect(reason))
            Storage.close(conn)
            {:stop, {:wal_replay_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("MachineActor[#{id}] storage init failed", reason: inspect(reason))
        {:stop, {:storage_init_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.metadata.state, state}
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_full_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:transition, transition_type, opts}, from, state) do
    operation_id = generate_operation_id()

    current_state = state.metadata.state
    target_state = FSM.resolve_target_state(transition_type, opts)

    case FSM.validate_transition(current_state, target_state) do
      :ok ->
        case check_capability(state.metadata.capabilities, transition_type) do
          :ok ->
            case state.operation_lock do
              nil ->
                locked_state = %{state | operation_lock: {operation_id, from, transition_type}}

                wal_entry = %{
                  operation_id: operation_id,
                  from_state: current_state,
                  to_state: target_state,
                  transition_type: transition_type,
                  opts: opts,
                  timestamp: DateTime.utc_now(),
                  status: :pending
                }

                case WAL.append(state.conn, wal_entry) do
                  {:ok, wal_seq} ->
                    Logger.info("MachineActor[#{state.id}] WAL written",
                      operation_id: operation_id,
                      transition: "#{current_state} -> #{target_state}",
                      wal_seq: wal_seq
                    )

                    send(self(), {:execute_transition, operation_id, wal_entry, from})

                    {:noreply, locked_state}

                  {:error, reason} ->
                    Logger.error("MachineActor[#{state.id}] WAL write failed",
                      operation_id: operation_id,
                      reason: inspect(reason)
                    )

                    {:reply, {:error, {:wal_write_failed, reason}}, state}
                end

              {locked_op_id, _locked_from, _locked_type} ->
                {:reply, {:error, {:locked_by_operation, locked_op_id}}, state}
            end

          {:error, missing_cap} ->
            {:reply, {:error, {:missing_capability, missing_cap}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_snapshot, _from, state) do
    snapshot = %{
      id: state.id,
      state: state.metadata.state,
      region: state.metadata.region,
      image: state.metadata.image,
      size: state.metadata.size,
      capabilities: state.metadata.capabilities,
      locked_by: state.operation_lock && elem(state.operation_lock, 0),
      created_at: state.metadata.created_at,
      updated_at: state.metadata.updated_at,
      version: state.metadata.version,
      stats: state.stats
    }

    {:reply, {:ok, snapshot}, state}
  end

  @impl true
  def handle_call({:get_history, opts}, _from, state) do
    case WAL.read_history(state.conn, opts) do
      {:ok, entries} ->
        {:reply, {:ok, entries}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:execute_transition, operation_id, wal_entry, caller}, state) do
    start_time = System.monotonic_time(:millisecond)

    result = perform_transition_work(wal_entry.transition_type, wal_entry.opts, state)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, new_metadata} ->
        :ok = WAL.mark_completed(state.conn, operation_id)

        updated_metadata = %{
          new_metadata
          | updated_at: DateTime.utc_now(),
            version: new_metadata.version + 1
        }

        :ok = Storage.save_metadata(state.conn, updated_metadata)

        new_state = %{
          state
          | metadata: updated_metadata,
            operation_lock: nil,
            stats: update_stats(state.stats, duration_ms, :success)
        }

        transition_result = %{
          from: wal_entry.from_state,
          to: wal_entry.to_state,
          timestamp: wal_entry.timestamp,
          duration_ms: duration_ms
        }

        GenServer.reply(caller, {:ok, transition_result})

        :telemetry.execute(
          [:machine_actor, :transition, :completed],
          %{duration_ms: duration_ms},
          %{
            id: state.id,
            from: wal_entry.from_state,
            to: wal_entry.to_state,
            operation_id: operation_id
          }
        )

        Logger.info("MachineActor[#{state.id}] transition completed",
          operation_id: operation_id,
          transition: "#{wal_entry.from_state} -> #{wal_entry.to_state}",
          duration_ms: duration_ms
        )

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "machine_actor:#{state.id}",
          {:state_changed, updated_metadata}
        )

        {:noreply, new_state}

      {:error, reason} ->
        :ok = WAL.mark_failed(state.conn, operation_id, reason)

        new_state = %{
          state
          | operation_lock: nil,
            stats: update_stats(state.stats, duration_ms, :error)
        }

        GenServer.reply(caller, {:error, reason})

        Logger.error("MachineActor[#{state.id}] transition failed",
          operation_id: operation_id,
          transition: "#{wal_entry.from_state} -> #{wal_entry.to_state}",
          reason: inspect(reason),
          duration_ms: duration_ms
        )

        :telemetry.execute(
          [:machine_actor, :transition, :failed],
          %{duration_ms: duration_ms},
          %{id: state.id, reason: reason}
        )

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:reconcile_pending, pending_operations}, state) do
    Logger.warning("MachineActor[#{state.id}] reconciling pending operations",
      count: length(pending_operations)
    )

    Enum.each(pending_operations, fn op ->
      Logger.warning("MachineActor[#{state.id}] incomplete operation",
        operation_id: op.operation_id,
        transition: "#{op.from_state} -> #{op.to_state}",
        age_ms: DateTime.diff(DateTime.utc_now(), op.timestamp, :millisecond)
      )
    end)

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("MachineActor[#{state.id}] terminating", reason: inspect(reason))

    Storage.close(state.conn)

    Orchestrator.ResourceManager.release_resources(state.id)

    Logger.debug("Resources released for machine",
      machine_id: state.id,
      reason: inspect(reason)
    )

    :ok
  end

  defp via_tuple(id) do
    {:via, Registry, {Orchestrator.MachineActorRegistry, id}}
  end

  defp generate_operation_id do
    "op_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  defp check_capability(capabilities, transition_type) do
    required_cap =
      case transition_type do
        :start -> :start
        :stop -> :stop
        :destroy -> :destroy
        :migrate -> :migrate
        :suspend -> :stop
        :resume -> :start
        :restart -> :start
        _ -> :unknown
      end

    if required_cap in capabilities do
      :ok
    else
      {:error, required_cap}
    end
  end

  defp perform_transition_work(transition_type, opts, state) do
    if Keyword.get(opts, :simulate_failure) do
      {:error, :simulated_failure}
    else
      new_state =
        case transition_type do
          :start ->
            Process.sleep(Enum.random(50..150))
            :running

          :stop ->
            Process.sleep(Enum.random(30..80))
            :stopped

          :destroy ->
            Process.sleep(Enum.random(20..50))
            :destroyed

          :suspend ->
            Process.sleep(Enum.random(40..100))
            :suspended

          :resume ->
            Process.sleep(Enum.random(50..120))
            :running

          :restart ->
            Process.sleep(Enum.random(100..200))
            :running

          :migrate ->
            target_region = Keyword.fetch!(opts, :target_region)
            Process.sleep(Enum.random(200..500))
            {:running, %{migrated_to: target_region}}
        end

      updated_metadata =
        case new_state do
          {state_atom, extra_meta} ->
            Map.merge(state.metadata, %{state: state_atom} |> Map.merge(extra_meta))

          state_atom ->
            %{state.metadata | state: state_atom}
        end

      {:ok, updated_metadata}
    end
  end

  defp update_stats(stats, duration_ms, result) do
    new_count = stats.transitions + 1

    new_avg =
      (stats.avg_transition_ms * stats.transitions + duration_ms) / new_count

    %{
      stats
      | transitions: new_count,
        errors: if(result == :error, do: stats.errors + 1, else: stats.errors),
        avg_transition_ms: new_avg
    }
  end
end
