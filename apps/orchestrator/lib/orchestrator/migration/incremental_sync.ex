defmodule Orchestrator.Migration.IncrementalSync do
  use GenServer
  require Logger

  alias Orchestrator.Migration.DirtyPageTracker
  alias Orchestrator.Migration.StateTransfer

  @type machine_id :: String.t()
  @type sync_result :: {:ok, map()} | {:error, term()}

  @max_iterations 10
  @convergence_threshold 100
  @write_rate_alpha 0.3
  @min_iteration_interval_ms 1000

  @spec sync_until_convergence(machine_id(), String.t(), keyword()) :: sync_result()
  def sync_until_convergence(machine_id, destination, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:sync_until_convergence, machine_id, destination, opts},
      :infinity
    )
  end

  @spec get_progress(machine_id()) :: map() | nil
  def get_progress(machine_id) do
    GenServer.call(__MODULE__, {:get_progress, machine_id})
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:sync_until_convergence, machine_id, destination, opts}, _from, state) do
    max_iterations = Keyword.get(opts, :max_iterations, @max_iterations)
    convergence_threshold = Keyword.get(opts, :convergence_threshold, @convergence_threshold)
    transfer_speed = Keyword.get(opts, :transfer_speed, 10)

    Logger.info("Starting incremental sync",
      machine_id: machine_id,
      destination: destination,
      max_iterations: max_iterations,
      convergence_threshold: convergence_threshold
    )

    sync_state = %{
      machine_id: machine_id,
      destination: destination,
      iteration: 0,
      dirty_history: [],
      write_rate_estimate: 0.0,
      transfer_speed: transfer_speed,
      convergence_threshold: convergence_threshold,
      start_time: DateTime.utc_now()
    }

    :telemetry.execute(
      [:orchestrator, :migration, :incremental_sync_started],
      %{},
      %{machine_id: machine_id, destination: destination}
    )

    state_with_sync = Map.put(state, machine_id, sync_state)

    result = run_iterations(sync_state, max_iterations)

    state_after_sync = Map.delete(state_with_sync, machine_id)

    case result do
      {:ready_for_cutover, stats} ->
        Logger.info("Incremental sync converged",
          machine_id: machine_id,
          iterations: stats.iterations,
          final_dirty_pages: stats.final_dirty_pages
        )

        :telemetry.execute(
          [:orchestrator, :migration, :incremental_sync_converged],
          %{
            iterations: stats.iterations,
            total_pages_synced: stats.total_pages_synced,
            duration_seconds: stats.duration_seconds
          },
          %{machine_id: machine_id}
        )

        {:reply, {:ready_for_cutover, stats}, state_after_sync}

      {:error, reason} = error ->
        Logger.error("Incremental sync failed",
          machine_id: machine_id,
          reason: reason
        )

        :telemetry.execute(
          [:orchestrator, :migration, :incremental_sync_failed],
          %{},
          %{machine_id: machine_id, reason: reason}
        )

        {:reply, error, state_after_sync}
    end
  end

  @impl true
  def handle_call({:get_progress, machine_id}, _from, state) do
    progress =
      case Map.get(state, machine_id) do
        nil ->
          nil

        sync_state ->
          %{
            iteration: sync_state.iteration,
            write_rate_estimate: sync_state.write_rate_estimate,
            dirty_history: sync_state.dirty_history,
            elapsed_seconds: DateTime.diff(DateTime.utc_now(), sync_state.start_time, :second)
          }
      end

    {:reply, progress, state}
  end

  defp run_iterations(sync_state, max_iterations) do
    run_iterations_loop(sync_state, max_iterations, 1, [])
  end

  defp run_iterations_loop(sync_state, max_iterations, iteration, all_stats)
       when iteration <= max_iterations do
    Logger.info("Starting iteration #{iteration}", machine_id: sync_state.machine_id)

    iteration_start = System.monotonic_time(:millisecond)

    dirty_pages = DirtyPageTracker.get_dirty_pages(sync_state.machine_id)
    dirty_count = length(dirty_pages)

    Logger.debug("Dirty pages count",
      machine_id: sync_state.machine_id,
      iteration: iteration,
      dirty_count: dirty_count
    )

    if dirty_count < sync_state.convergence_threshold do
      if sync_state.write_rate_estimate < sync_state.transfer_speed or iteration == 1 do
        duration = DateTime.diff(DateTime.utc_now(), sync_state.start_time, :second)
        total_pages = Enum.reduce(all_stats, 0, fn s, acc -> acc + s.pages_synced end)

        stats = %{
          iterations: iteration - 1,
          final_dirty_pages: dirty_count,
          total_pages_synced: total_pages,
          write_rate: sync_state.write_rate_estimate,
          duration_seconds: duration
        }

        {:ready_for_cutover, stats}
      else
        do_sync_iteration(
          sync_state,
          iteration,
          dirty_pages,
          dirty_count,
          iteration_start,
          max_iterations,
          all_stats
        )
      end
    else
      do_sync_iteration(
        sync_state,
        iteration,
        dirty_pages,
        dirty_count,
        iteration_start,
        max_iterations,
        all_stats
      )
    end
  end

  defp run_iterations_loop(sync_state, _max_iterations, iteration, _all_stats) do
    Logger.warning("Max iterations reached without convergence",
      machine_id: sync_state.machine_id,
      iterations: iteration - 1
    )

    {:error, :max_iterations}
  end

  defp do_sync_iteration(
         sync_state,
         iteration,
         dirty_pages,
         dirty_count,
         iteration_start,
         max_iterations,
         all_stats
       ) do
    sync_result =
      StateTransfer.sync_dirty_pages(
        sync_state.machine_id,
        sync_state.destination,
        dirty_pages
      )

    case sync_result do
      {:ok, pages_synced} ->
        page_numbers = Enum.map(dirty_pages, & &1.page_number)
        :ok = DirtyPageTracker.clear_synced_pages(sync_state.machine_id, page_numbers)

        iteration_end = System.monotonic_time(:millisecond)
        iteration_duration_ms = iteration_end - iteration_start

        instant_write_rate = dirty_count / max(iteration_duration_ms / 1000, 1)

        new_write_rate =
          if sync_state.write_rate_estimate == 0.0 do
            instant_write_rate
          else
            @write_rate_alpha * instant_write_rate +
              (1 - @write_rate_alpha) * sync_state.write_rate_estimate
          end

        iteration_stats = %{
          iteration: iteration,
          pages_synced: pages_synced,
          dirty_count: dirty_count,
          duration_ms: iteration_duration_ms,
          instant_write_rate: instant_write_rate,
          write_rate_estimate: new_write_rate
        }

        Logger.info("Iteration completed",
          machine_id: sync_state.machine_id,
          iteration: iteration,
          pages_synced: pages_synced,
          dirty_count: dirty_count,
          duration_ms: iteration_duration_ms,
          write_rate_estimate: Float.round(new_write_rate, 2)
        )

        :telemetry.execute(
          [:orchestrator, :migration, :incremental_sync_iteration],
          %{
            pages_synced: pages_synced,
            dirty_count: dirty_count,
            duration_ms: iteration_duration_ms
          },
          %{machine_id: sync_state.machine_id, iteration: iteration}
        )

        updated_state = %{
          sync_state
          | iteration: iteration,
            dirty_history: [iteration_stats | sync_state.dirty_history],
            write_rate_estimate: new_write_rate
        }

        if detect_non_convergence?(updated_state.dirty_history) do
          Logger.error("Non-convergence detected, write rate exceeds transfer rate",
            machine_id: sync_state.machine_id,
            write_rate: new_write_rate,
            transfer_speed: sync_state.transfer_speed
          )

          {:error, :non_convergence}
        else
          if iteration_duration_ms < @min_iteration_interval_ms do
            sleep_ms = @min_iteration_interval_ms - iteration_duration_ms
            Logger.debug("Sleeping between iterations", sleep_ms: sleep_ms)
            Process.sleep(sleep_ms)
          end

          run_iterations_loop(updated_state, max_iterations, iteration + 1, [
            iteration_stats | all_stats
          ])
        end
    end
  end

  defp detect_non_convergence?(dirty_history) when length(dirty_history) < 3 do
    false
  end

  defp detect_non_convergence?(dirty_history) do
    recent =
      dirty_history
      |> Enum.take(3)
      |> Enum.reverse()

    growing? =
      recent
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [prev, curr] -> curr.dirty_count > prev.dirty_count end)

    if growing? do
      Logger.warning("Dirty set growing over last 3 iterations",
        history: Enum.map(recent, fn s -> {s.iteration, s.dirty_count} end)
      )
    end

    growing?
  end
end
