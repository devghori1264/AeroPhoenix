defmodule Orchestrator.LiveMigration.Coordinator do
  use GenServer
  require Logger
  alias Orchestrator.LiveMigration.{Checkpointer, StateTransfer, Cutover}
  alias Orchestrator.{FlydClient, Manager, Repo}
  alias Orchestrator.Reconciliation.Engine, as: ReconciliationEngine
  @type migration_id :: String.t()
  @type machine_id :: String.t()
  @type region :: String.t()
  @type migration_phase ::
          :pre_flight
          | :checkpoint
          | :incremental_sync
          | :final_sync
          | :cutover
          | :verification
          | :cleanup
          | :completed
          | :failed
          | :rolled_back
  @type migration_state :: %{
          migration_id: migration_id(),
          machine_id: machine_id(),
          source_region: region(),
          target_region: region(),
          phase: migration_phase(),
          strategy: :pre_copy | :post_copy | :hybrid,
          checkpoint_id: String.t() | nil,
          bytes_transferred: non_neg_integer(),
          total_bytes: non_neg_integer(),
          iterations: non_neg_integer(),
          started_at: DateTime.t(),
          phase_started_at: DateTime.t(),
          downtime_ms: non_neg_integer(),
          freeze_time_ms: non_neg_integer(),
          errors: [map()],
          config: map()
        }
  @max_iterations 10
  @freeze_threshold_ms 100
  @dirty_page_threshold 0.05
  @transfer_parallelism 4
  @checksum_algorithm :sha256
  @rollback_timeout_ms 30_000
  @spec start_migration(machine_id(), region(), keyword()) ::
          {:ok, migration_id()} | {:error, term()}
  def start_migration(machine_id, target_region, opts \\ []) do
    GenServer.start_link(__MODULE__, {machine_id, target_region, opts},
      name: via_tuple(machine_id)
    )
  end

  @spec get_status(migration_id()) :: {:ok, map()} | {:error, :not_found}
  def get_status(migration_id) do
    case Registry.lookup(Orchestrator.LiveMigrationRegistry, migration_id) do
      [{pid, _}] ->
        GenServer.call(pid, :get_status)

      [] ->
        get_completed_migration_status(migration_id)
    end
  end

  @spec pause_migration(migration_id()) :: :ok | {:error, term()}
  def pause_migration(migration_id) do
    with {:ok, pid} <- find_migration_process(migration_id) do
      GenServer.call(pid, :pause)
    end
  end

  @spec resume_migration(migration_id()) :: :ok | {:error, term()}
  def resume_migration(migration_id) do
    with {:ok, pid} <- find_migration_process(migration_id) do
      GenServer.call(pid, :resume)
    end
  end

  @spec cancel_migration(migration_id()) :: {:ok, map()} | {:error, term()}
  def cancel_migration(migration_id) do
    with {:ok, pid} <- find_migration_process(migration_id) do
      GenServer.call(pid, :cancel, @rollback_timeout_ms)
    end
  end

  @impl true
  def init({machine_id, target_region, opts}) do
    migration_id = generate_migration_id()

    Logger.info("LiveMigration coordinator starting",
      migration_id: migration_id,
      machine_id: machine_id,
      target_region: target_region
    )

    {:ok, machine} = Manager.get_machine(machine_id)
    source_region = machine.region

    config = %{
      strategy: Keyword.get(opts, :strategy, :hybrid),
      max_iterations: Keyword.get(opts, :max_iterations, @max_iterations),
      freeze_threshold_ms: Keyword.get(opts, :freeze_threshold_ms, @freeze_threshold_ms),
      parallelism: Keyword.get(opts, :parallelism, @transfer_parallelism),
      verify_checksums: Keyword.get(opts, :verify_checksums, true),
      auto_rollback: Keyword.get(opts, :auto_rollback, true),
      preserve_ip: Keyword.get(opts, :preserve_ip, false),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    state = %{
      migration_id: migration_id,
      machine_id: machine_id,
      source_region: source_region,
      target_region: target_region,
      phase: :pre_flight,
      strategy: config.strategy,
      checkpoint_id: nil,
      bytes_transferred: 0,
      total_bytes: 0,
      iterations: 0,
      started_at: DateTime.utc_now(),
      phase_started_at: DateTime.utc_now(),
      downtime_ms: 0,
      freeze_time_ms: 0,
      errors: [],
      config: config,
      paused: false,
      cancelled: false
    }

    :ets.insert(:live_migrations, {migration_id, machine_id, self()})
    send(self(), :execute_migration)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = build_status_response(state)
    {:reply, {:ok, status}, state}
  end

  def handle_call(:pause, _from, state) do
    Logger.info("Pausing live migration", migration_id: state.migration_id)
    new_state = %{state | paused: true}

    :telemetry.execute(
      [:orchestrator, :live_migration, :paused],
      %{},
      %{migration_id: state.migration_id, phase: state.phase}
    )

    {:reply, :ok, new_state}
  end

  def handle_call(:resume, _from, state) do
    Logger.info("Resuming live migration", migration_id: state.migration_id)
    new_state = %{state | paused: false}
    send(self(), :execute_migration)

    :telemetry.execute(
      [:orchestrator, :live_migration, :resumed],
      %{},
      %{migration_id: state.migration_id, phase: state.phase}
    )

    {:reply, :ok, new_state}
  end

  def handle_call(:cancel, _from, state) do
    Logger.warning("Cancelling live migration", migration_id: state.migration_id)
    new_state = %{state | cancelled: true}
    rollback_result = perform_rollback(new_state)
    final_state = %{new_state | phase: :rolled_back}
    persist_migration_record(final_state)

    :telemetry.execute(
      [:orchestrator, :live_migration, :cancelled],
      %{},
      %{migration_id: state.migration_id, phase: state.phase}
    )

    {:reply, rollback_result, final_state}
  end

  @impl true
  def handle_info(:execute_migration, %{paused: true} = state) do
    {:noreply, state}
  end

  def handle_info(:execute_migration, %{cancelled: true} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:execute_migration, state) do
    new_state =
      case state.phase do
        :pre_flight ->
          execute_pre_flight(state)

        :checkpoint ->
          execute_checkpoint(state)

        :incremental_sync ->
          execute_incremental_sync(state)

        :final_sync ->
          execute_final_sync(state)

        :cutover ->
          execute_cutover(state)

        :verification ->
          execute_verification(state)

        :cleanup ->
          execute_cleanup(state)

        :completed ->
          Logger.info("Live migration completed", migration_id: state.migration_id)
          state

        :failed ->
          Logger.error("Live migration failed", migration_id: state.migration_id)

          if state.config.auto_rollback do
            perform_rollback(state)
          end

          state

        :rolled_back ->
          Logger.info("Live migration rolled back", migration_id: state.migration_id)
          state
      end

    if new_state.phase not in [:completed, :failed, :rolled_back] do
      send(self(), :execute_migration)
    else
      persist_migration_record(new_state)
    end

    {:noreply, new_state}
  end

  defp execute_pre_flight(state) do
    Logger.info("Phase: Pre-flight validation", migration_id: state.migration_id)
    phase_start = System.monotonic_time(:millisecond)

    validations = [
      validate_source_availability(state),
      validate_target_capacity(state),
      validate_network_connectivity(state),
      validate_version_compatibility(state),
      estimate_migration_size(state)
    ]

    case Enum.find(validations, fn {result, _} -> result == :error end) do
      nil ->
        {_, total_bytes} = List.last(validations)
        duration = System.monotonic_time(:millisecond) - phase_start

        Logger.info("Pre-flight validation passed",
          migration_id: state.migration_id,
          total_bytes: total_bytes,
          duration_ms: duration
        )

        :telemetry.execute(
          [:orchestrator, :live_migration, :pre_flight, :completed],
          %{duration_ms: duration, total_bytes: total_bytes},
          %{migration_id: state.migration_id}
        )

        %{
          state
          | phase: :checkpoint,
            phase_started_at: DateTime.utc_now(),
            total_bytes: total_bytes
        }

      {:error, reason} ->
        Logger.error("Pre-flight validation failed",
          migration_id: state.migration_id,
          reason: reason
        )

        %{state | phase: :failed, errors: [%{phase: :pre_flight, reason: reason} | state.errors]}
    end
  end

  defp execute_checkpoint(state) do
    Logger.info("Phase: Creating checkpoint", migration_id: state.migration_id)
    phase_start = System.monotonic_time(:millisecond)

    case Checkpointer.create_checkpoint(state.machine_id, state.source_region, %{
           strategy: state.strategy,
           compression: true,
           incremental: true
         }) do
      {:ok, checkpoint_id, metadata} ->
        duration = System.monotonic_time(:millisecond) - phase_start

        Logger.info("Checkpoint created",
          migration_id: state.migration_id,
          checkpoint_id: checkpoint_id,
          size_bytes: metadata.size_bytes,
          duration_ms: duration
        )

        :telemetry.execute(
          [:orchestrator, :live_migration, :checkpoint, :created],
          %{duration_ms: duration, size_bytes: metadata.size_bytes},
          %{migration_id: state.migration_id, checkpoint_id: checkpoint_id}
        )

        %{
          state
          | phase: :incremental_sync,
            phase_started_at: DateTime.utc_now(),
            checkpoint_id: checkpoint_id
        }

      {:error, reason} ->
        Logger.error("Checkpoint creation failed",
          migration_id: state.migration_id,
          reason: reason
        )

        %{state | phase: :failed, errors: [%{phase: :checkpoint, reason: reason} | state.errors]}
    end
  end

  defp execute_incremental_sync(state) do
    Logger.info("Phase: Incremental sync (iteration #{state.iterations + 1})",
      migration_id: state.migration_id
    )

    phase_start = System.monotonic_time(:millisecond)

    case StateTransfer.transfer_incremental(
           state.checkpoint_id,
           state.source_region,
           state.target_region,
           %{
             parallelism: state.config.parallelism,
             verify_checksums: state.config.verify_checksums,
             compression: true
           }
         ) do
      {:ok, transfer_result} ->
        duration = System.monotonic_time(:millisecond) - phase_start
        new_bytes = state.bytes_transferred + transfer_result.bytes_transferred
        new_iterations = state.iterations + 1
        dirty_ratio = transfer_result.dirty_pages / max(transfer_result.total_pages, 1)

        Logger.info("Incremental sync completed",
          migration_id: state.migration_id,
          iteration: new_iterations,
          bytes_transferred: transfer_result.bytes_transferred,
          dirty_ratio: Float.round(dirty_ratio, 4),
          duration_ms: duration
        )

        :telemetry.execute(
          [:orchestrator, :live_migration, :incremental_sync, :completed],
          %{
            duration_ms: duration,
            bytes_transferred: transfer_result.bytes_transferred,
            dirty_ratio: dirty_ratio
          },
          %{migration_id: state.migration_id, iteration: new_iterations}
        )

        should_finalize =
          dirty_ratio < @dirty_page_threshold or
            new_iterations >= state.config.max_iterations

        next_phase = if should_finalize, do: :final_sync, else: :incremental_sync

        %{
          state
          | phase: next_phase,
            phase_started_at: DateTime.utc_now(),
            bytes_transferred: new_bytes,
            iterations: new_iterations
        }

      {:error, reason} ->
        Logger.error("Incremental sync failed",
          migration_id: state.migration_id,
          iteration: state.iterations + 1,
          reason: reason
        )

        %{
          state
          | phase: :failed,
            errors: [
              %{phase: :incremental_sync, reason: reason, iteration: state.iterations + 1}
              | state.errors
            ]
        }
    end
  end

  defp execute_final_sync(state) do
    Logger.info("Phase: Final sync (freeze source)", migration_id: state.migration_id)
    freeze_start = System.monotonic_time(:millisecond)

    case FlydClient.pause_machine(state.source_region, state.machine_id) do
      :ok ->
        case StateTransfer.transfer_final(
               state.checkpoint_id,
               state.source_region,
               state.target_region,
               %{verify_checksums: state.config.verify_checksums}
             ) do
          {:ok, transfer_result} ->
            freeze_time = System.monotonic_time(:millisecond) - freeze_start

            Logger.info("Final sync completed",
              migration_id: state.migration_id,
              freeze_time_ms: freeze_time,
              bytes_transferred: transfer_result.bytes_transferred
            )

            if freeze_time > state.config.freeze_threshold_ms do
              Logger.warning("Freeze time exceeded threshold",
                migration_id: state.migration_id,
                freeze_time_ms: freeze_time,
                threshold_ms: state.config.freeze_threshold_ms
              )
            end

            :telemetry.execute(
              [:orchestrator, :live_migration, :final_sync, :completed],
              %{
                freeze_time_ms: freeze_time,
                bytes_transferred: transfer_result.bytes_transferred
              },
              %{migration_id: state.migration_id}
            )

            %{
              state
              | phase: :cutover,
                phase_started_at: DateTime.utc_now(),
                freeze_time_ms: freeze_time,
                bytes_transferred: state.bytes_transferred + transfer_result.bytes_transferred
            }

          {:error, reason} ->
            FlydClient.resume_machine(state.source_region, state.machine_id)

            Logger.error("Final sync failed",
              migration_id: state.migration_id,
              reason: reason
            )

            %{
              state
              | phase: :failed,
                errors: [%{phase: :final_sync, reason: reason} | state.errors]
            }
        end

      {:error, reason} ->
        Logger.error("Failed to pause source machine",
          migration_id: state.migration_id,
          reason: reason
        )

        %{
          state
          | phase: :failed,
            errors: [
              %{phase: :final_sync, reason: "pause_failed: #{inspect(reason)}"} | state.errors
            ]
        }
    end
  end

  defp execute_cutover(state) do
    Logger.info("Phase: Network cutover", migration_id: state.migration_id)
    cutover_start = System.monotonic_time(:millisecond)

    case Cutover.perform_cutover(
           state.machine_id,
           state.source_region,
           state.target_region,
           %{
             preserve_ip: state.config.preserve_ip,
             dns_ttl: 60,
             traffic_replay: true
           }
         ) do
      {:ok, cutover_result} ->
        cutover_time = System.monotonic_time(:millisecond) - cutover_start
        total_downtime = state.freeze_time_ms + cutover_time

        Logger.info("Cutover completed",
          migration_id: state.migration_id,
          cutover_time_ms: cutover_time,
          total_downtime_ms: total_downtime,
          new_endpoint: cutover_result.new_endpoint
        )

        :telemetry.execute(
          [:orchestrator, :live_migration, :cutover, :completed],
          %{cutover_time_ms: cutover_time, total_downtime_ms: total_downtime},
          %{migration_id: state.migration_id}
        )

        %{
          state
          | phase: :verification,
            phase_started_at: DateTime.utc_now(),
            downtime_ms: total_downtime
        }

      {:error, reason} ->
        Logger.error("Cutover failed",
          migration_id: state.migration_id,
          reason: reason
        )

        %{state | phase: :failed, errors: [%{phase: :cutover, reason: reason} | state.errors]}
    end
  end

  defp execute_verification(state) do
    Logger.info("Phase: Post-migration verification", migration_id: state.migration_id)
    phase_start = System.monotonic_time(:millisecond)

    case ReconciliationEngine.reconcile_machine(state.machine_id, %{
           level: :deep,
           verify_checksums: true,
           source_region: state.source_region,
           target_region: state.target_region
         }) do
      {:ok, reconciliation_result} ->
        duration = System.monotonic_time(:millisecond) - phase_start

        if reconciliation_result.has_drift do
          Logger.warning("Post-migration drift detected",
            migration_id: state.migration_id,
            severity: reconciliation_result.severity,
            drift_count: length(reconciliation_result.inconsistencies)
          )

          if reconciliation_result.severity in [:critical, :major] do
            %{
              state
              | phase: :failed,
                errors: [
                  %{
                    phase: :verification,
                    reason: "critical_drift_detected",
                    details: reconciliation_result
                  }
                  | state.errors
                ]
            }
          else
            Logger.info("Minor drift acceptable, proceeding to cleanup",
              migration_id: state.migration_id
            )

            %{state | phase: :cleanup, phase_started_at: DateTime.utc_now()}
          end
        else
          Logger.info("Verification passed - no drift detected",
            migration_id: state.migration_id,
            duration_ms: duration
          )

          :telemetry.execute(
            [:orchestrator, :live_migration, :verification, :completed],
            %{duration_ms: duration},
            %{migration_id: state.migration_id}
          )

          %{state | phase: :cleanup, phase_started_at: DateTime.utc_now()}
        end

      {:error, reason} ->
        Logger.error("Verification failed",
          migration_id: state.migration_id,
          reason: reason
        )

        %{
          state
          | phase: :failed,
            errors: [%{phase: :verification, reason: reason} | state.errors]
        }
    end
  end

  defp execute_cleanup(state) do
    Logger.info("Phase: Cleanup", migration_id: state.migration_id)
    phase_start = System.monotonic_time(:millisecond)

    case FlydClient.destroy_machine(state.source_region, state.machine_id) do
      :ok ->
        Checkpointer.delete_checkpoint(state.checkpoint_id)
        duration = System.monotonic_time(:millisecond) - phase_start
        total_duration = DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)

        Logger.info("Live migration completed successfully",
          migration_id: state.migration_id,
          total_duration_ms: total_duration,
          downtime_ms: state.downtime_ms,
          freeze_time_ms: state.freeze_time_ms,
          bytes_transferred: state.bytes_transferred,
          iterations: state.iterations
        )

        :telemetry.execute(
          [:orchestrator, :live_migration, :completed],
          %{
            total_duration_ms: total_duration,
            downtime_ms: state.downtime_ms,
            freeze_time_ms: state.freeze_time_ms,
            bytes_transferred: state.bytes_transferred,
            iterations: state.iterations
          },
          %{migration_id: state.migration_id}
        )

        %{state | phase: :completed}

      {:error, reason} ->
        Logger.warning("Cleanup failed (non-critical)",
          migration_id: state.migration_id,
          reason: reason
        )

        %{state | phase: :completed}
    end
  end

  defp validate_source_availability(state) do
    case FlydClient.get_machine_health(state.source_region, state.machine_id) do
      {:ok, health} when health.status == "healthy" ->
        {:ok, :source_available}

      {:ok, health} ->
        {:error, {:unhealthy_source, health.status}}

      error ->
        error
    end
  end

  defp validate_target_capacity(state) do
    case FlydClient.get_region_capacity(state.target_region) do
      {:ok, capacity} when capacity.available_slots > 0 ->
        {:ok, :target_has_capacity}

      {:ok, _capacity} ->
        {:error, :no_target_capacity}

      error ->
        error
    end
  end

  defp validate_network_connectivity(state) do
    case FlydClient.ping_region(state.source_region, state.target_region) do
      {:ok, latency_ms} when latency_ms < 1000 ->
        {:ok, {:network_ok, latency_ms}}

      {:ok, latency_ms} ->
        Logger.warning("High network latency detected",
          latency_ms: latency_ms
        )

        {:ok, {:network_slow, latency_ms}}

      error ->
        {:error, {:network_unreachable, error}}
    end
  end

  defp validate_version_compatibility(_state) do
    {:ok, :compatible}
  end

  defp estimate_migration_size(state) do
    case FlydClient.get_machine_size(state.source_region, state.machine_id) do
      {:ok, size_bytes} ->
        {:ok, size_bytes}

      error ->
        Logger.warning("Could not determine machine size, using estimate")
        {:ok, 1_073_741_824}
    end
  end

  defp perform_rollback(state) do
    Logger.warning("Performing rollback", migration_id: state.migration_id)
    rollback_start = System.monotonic_time(:millisecond)
    FlydClient.resume_machine(state.source_region, state.machine_id)
    FlydClient.destroy_machine(state.target_region, state.machine_id)

    if state.checkpoint_id do
      Checkpointer.delete_checkpoint(state.checkpoint_id)
    end

    rollback_duration = System.monotonic_time(:millisecond) - rollback_start

    Logger.info("Rollback completed",
      migration_id: state.migration_id,
      duration_ms: rollback_duration
    )

    :telemetry.execute(
      [:orchestrator, :live_migration, :rollback, :completed],
      %{duration_ms: rollback_duration},
      %{migration_id: state.migration_id, failed_phase: state.phase}
    )

    {:ok,
     %{
       rolled_back: true,
       duration_ms: rollback_duration,
       failed_phase: state.phase,
       errors: state.errors
     }}
  end

  defp build_status_response(state) do
    progress_percent =
      if state.total_bytes > 0 do
        trunc(state.bytes_transferred / state.total_bytes * 100)
      else
        0
      end

    %{
      migration_id: state.migration_id,
      machine_id: state.machine_id,
      phase: state.phase,
      strategy: state.strategy,
      progress_percent: progress_percent,
      bytes_transferred: state.bytes_transferred,
      total_bytes: state.total_bytes,
      iterations: state.iterations,
      downtime_ms: state.downtime_ms,
      freeze_time_ms: state.freeze_time_ms,
      started_at: state.started_at,
      paused: state.paused,
      errors: state.errors
    }
  end

  defp persist_migration_record(state) do
    Logger.debug("Persisting migration record", migration_id: state.migration_id)
    :ok
  end

  defp get_completed_migration_status(migration_id) do
    {:error, :not_found}
  end

  defp find_migration_process(migration_id) do
    case Registry.lookup(Orchestrator.LiveMigrationRegistry, migration_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp generate_migration_id do
    "lm_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp via_tuple(machine_id) do
    {:via, Registry, {Orchestrator.LiveMigrationRegistry, machine_id}}
  end
end
