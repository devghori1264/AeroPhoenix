defmodule Orchestrator.Migration.MigrationCoordinator do
  use GenServer
  require Logger

  alias Orchestrator.Migration.{ConnectionDrainer, StateTransfer}

  @type region :: atom()
  @type machine_id :: String.t()
  @type migration_opts :: keyword()

  @type state :: %{
          active_migrations: %{machine_id() => migration_state()},
          stats: %{
            completed: non_neg_integer(),
            failed: non_neg_integer(),
            rolled_back: non_neg_integer()
          }
        }

  @type migration_state :: %{
          machine_id: machine_id(),
          source_region: region(),
          dest_region: region(),
          phase: migration_phase(),
          started_at: integer(),
          restore_point: term()
        }

  @type migration_phase ::
          :pre_copy | :draining | :stop_and_copy | :dns_cutover | :verification | :completed

  @max_precopy_iterations 10
  @precopy_threshold_bytes 1_048_576
  @draining_timeout_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec migrate_machine(machine_id(), migration_opts()) ::
          {:ok, region()} | {:error, term()}
  def migrate_machine(machine_id, opts) do
    GenServer.call(__MODULE__, {:migrate, machine_id, opts}, :infinity)
  end

  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(_opts) do
    state = %{
      active_migrations: %{},
      stats: %{
        completed: 0,
        failed: 0,
        rolled_back: 0
      }
    }

    Logger.info("MigrationCoordinator started")

    {:ok, state}
  end

  @impl true
  def handle_call({:migrate, machine_id, opts}, _from, state) do
    source_region = Keyword.fetch!(opts, :source_region)
    dest_region = Keyword.fetch!(opts, :dest_region)
    enable_rollback = Keyword.get(opts, :enable_rollback, true)

    Logger.info("Starting live migration",
      machine_id: machine_id,
      source: source_region,
      dest: dest_region
    )

    restore_point =
      if enable_rollback do
        create_restore_point(machine_id, source_region)
      else
        nil
      end

    migration_state = %{
      machine_id: machine_id,
      source_region: source_region,
      dest_region: dest_region,
      phase: :pre_copy,
      started_at: System.monotonic_time(:millisecond),
      restore_point: restore_point
    }

    new_state = put_in(state, [:active_migrations, machine_id], migration_state)

    result =
      try do
        perform_migration(migration_state)
      rescue
        error ->
          Logger.error("Migration failed with exception",
            machine_id: machine_id,
            error: inspect(error)
          )

          {:error, {:exception, error}}
      end

    final_state =
      case result do
        {:ok, _dest_region} ->
          new_state
          |> update_in([:stats, :completed], &(&1 + 1))
          |> update_in([:active_migrations], &Map.delete(&1, machine_id))

        {:error, reason} when enable_rollback ->
          Logger.warning("Migration failed, initiating rollback", reason: reason)
          rollback_migration(migration_state)

          new_state
          |> update_in([:stats, :rolled_back], &(&1 + 1))
          |> update_in([:active_migrations], &Map.delete(&1, machine_id))

        {:error, _reason} ->
          new_state
          |> update_in([:stats, :failed], &(&1 + 1))
          |> update_in([:active_migrations], &Map.delete(&1, machine_id))
      end

    {:reply, result, final_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total = state.stats.completed + state.stats.failed + state.stats.rolled_back

    stats =
      Map.merge(state.stats, %{
        total_migrations: total,
        active_migrations: map_size(state.active_migrations),
        success_rate: if(total > 0, do: Float.round(state.stats.completed / total, 4), else: 0.0)
      })

    {:reply, stats, state}
  end

  defp perform_migration(migration_state) do
    machine_id = migration_state.machine_id
    dest_region = migration_state.dest_region

    with {:ok, dirty_bytes} <- phase_pre_copy(migration_state),
         :ok <- phase_connection_draining(migration_state),
         {:ok, downtime_ms} <- phase_stop_and_copy(migration_state, dirty_bytes),
         :ok <- phase_dns_cutover(migration_state),
         :ok <- phase_verification(migration_state) do
      total_duration = System.monotonic_time(:millisecond) - migration_state.started_at

      Logger.info("Migration completed successfully",
        machine_id: machine_id,
        dest_region: dest_region,
        total_duration_ms: total_duration,
        downtime_ms: downtime_ms
      )

      :telemetry.execute(
        [:orchestrator, :migration, :completed],
        %{total_duration_ms: total_duration, downtime_ms: downtime_ms},
        %{machine_id: machine_id, dest_region: dest_region}
      )

      {:ok, dest_region}
    else
      {:error, reason} = error ->
        Logger.error("Migration phase failed",
          machine_id: machine_id,
          phase: migration_state.phase,
          reason: reason
        )

        error
    end
  end

  defp phase_pre_copy(migration_state) do
    Logger.info("Phase 1: Pre-copy memory iteration", machine_id: migration_state.machine_id)

    dirty_bytes = simulate_precopy_iterations(migration_state)

    {:ok, dirty_bytes}
  end

  defp phase_connection_draining(migration_state) do
    Logger.info("Phase 2: Connection draining", machine_id: migration_state.machine_id)

    case ConnectionDrainer.drain_connections(
           migration_state.machine_id,
           timeout: @draining_timeout_ms
         ) do
      {:ok, forced_closes} ->
        :telemetry.execute(
          [:orchestrator, :migration, :draining_completed],
          %{forced_closes: forced_closes},
          %{machine_id: migration_state.machine_id}
        )

        :ok
    end
  end

  defp phase_stop_and_copy(migration_state, dirty_bytes) do
    Logger.info("Phase 3: Stop-and-copy",
      machine_id: migration_state.machine_id,
      dirty_bytes: dirty_bytes
    )

    start_time = System.monotonic_time(:millisecond)

    :ok = freeze_machine(migration_state.machine_id)

    :ok = StateTransfer.transfer_final_state(migration_state.machine_id, dirty_bytes)

    :ok = start_machine_in_new_region(migration_state.machine_id, migration_state.dest_region)

    downtime_ms = System.monotonic_time(:millisecond) - start_time

    Logger.info("Stop-and-copy completed", downtime_ms: downtime_ms)

    {:ok, downtime_ms}
  end

  defp phase_dns_cutover(migration_state) do
    Logger.info("Phase 4: DNS cutover", machine_id: migration_state.machine_id)

    :ok = update_health_checks(migration_state.machine_id, migration_state.dest_region)

    Process.sleep(1000)

    :ok
  end

  defp phase_verification(migration_state) do
    Logger.info("Phase 5: Verification", machine_id: migration_state.machine_id)

    case verify_new_region(migration_state.machine_id, migration_state.dest_region) do
      :healthy ->
        :ok
    end
  end

  defp simulate_precopy_iterations(migration_state) do
    initial_dirty = 1_000_000_000

    Enum.reduce_while(1..@max_precopy_iterations, initial_dirty, fn iteration, dirty_bytes ->
      new_dirty = round(dirty_bytes * 0.1)

      Logger.debug("Pre-copy iteration #{iteration}",
        dirty_bytes: dirty_bytes,
        reduction_pct: 90.0
      )

      :telemetry.execute(
        [:orchestrator, :migration, :precopy_iteration],
        %{iteration: iteration, dirty_bytes: dirty_bytes},
        %{machine_id: migration_state.machine_id}
      )

      if new_dirty <= @precopy_threshold_bytes do
        {:halt, new_dirty}
      else
        {:cont, new_dirty}
      end
    end)
  end

  defp create_restore_point(machine_id, region) do
    %{
      machine_id: machine_id,
      region: region,
      snapshot_id: "snapshot_#{machine_id}_#{System.monotonic_time()}",
      created_at: System.monotonic_time(:millisecond)
    }
  end

  defp rollback_migration(migration_state) do
    Logger.warning("Rolling back migration",
      machine_id: migration_state.machine_id,
      source: migration_state.source_region
    )

    update_health_checks(migration_state.machine_id, migration_state.source_region)

    if migration_state.restore_point do
      restore_from_snapshot(
        migration_state.machine_id,
        migration_state.restore_point.snapshot_id
      )
    end

    :telemetry.execute(
      [:orchestrator, :migration, :rollback],
      %{},
      %{machine_id: migration_state.machine_id}
    )

    :ok
  end

  defp freeze_machine(_machine_id), do: :ok
  defp start_machine_in_new_region(_machine_id, _region), do: :ok
  defp update_health_checks(_machine_id, _region), do: :ok
  defp restore_from_snapshot(_machine_id, _snapshot_id), do: :ok

  defp verify_new_region(_machine_id, _region) do
    :healthy
  end
end
