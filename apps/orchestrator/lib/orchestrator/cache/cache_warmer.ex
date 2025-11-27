defmodule Orchestrator.Cache.CacheWarmer do
  use GenServer
  require Logger

  @type state :: %{
          warming_in_progress: boolean(),
          last_warmup_at: integer() | nil,
          entries_loaded: non_neg_integer()
        }

  @warmup_batch_size 100
  @warmup_delay_between_batches_ms 50
  @background_refresh_interval_ms :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec warm_cache(GenServer.server()) :: :ok
  def warm_cache(server) do
    GenServer.cast(server, :warm_cache)
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(_opts) do
    state = %{
      warming_in_progress: false,
      last_warmup_at: nil,
      entries_loaded: 0
    }

    Logger.info("CacheWarmer started")

    {:ok, state}
  end

  @impl true
  def handle_cast(:warm_cache, state) do
    if state.warming_in_progress do
      Logger.warning("Cache warming already in progress, ignoring request")
      {:noreply, state}
    else
      spawn_link(fn -> perform_cache_warming() end)

      Process.send_after(self(), :refresh_cache, @background_refresh_interval_ms)

      {:noreply, %{state | warming_in_progress: true}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      warming_in_progress: state.warming_in_progress,
      last_warmup_at: state.last_warmup_at,
      entries_loaded: state.entries_loaded
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:warming_completed, entries_loaded, duration_ms}, state) do
    Logger.info("Cache warming completed",
      entries_loaded: entries_loaded,
      duration_ms: duration_ms
    )

    :telemetry.execute(
      [:orchestrator, :cache_warmer, :completed],
      %{duration_ms: duration_ms},
      %{entries_loaded: entries_loaded}
    )

    new_state = %{
      state
      | warming_in_progress: false,
        last_warmup_at: System.monotonic_time(:millisecond),
        entries_loaded: entries_loaded
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:refresh_cache, state) do
    spawn_link(fn -> perform_background_refresh() end)

    Process.send_after(self(), :refresh_cache, @background_refresh_interval_ms)

    {:noreply, state}
  end

  defp perform_cache_warming do
    parent = self()
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Starting cache warming")

    hot_machines = get_hot_machines()

    total_count = length(hot_machines)
    Logger.info("Found hot machines to warm", count: total_count)

    loaded_count =
      hot_machines
      |> Enum.chunk_every(@warmup_batch_size)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {batch, batch_idx}, acc ->
        preload_batch(batch)

        loaded = acc + length(batch)

        :telemetry.execute(
          [:orchestrator, :cache_warmer, :progress],
          %{loaded: loaded, total: total_count},
          %{}
        )

        Logger.debug("Cache warming progress",
          batch: batch_idx + 1,
          loaded: loaded,
          total: total_count
        )

        if loaded < total_count do
          Process.sleep(@warmup_delay_between_batches_ms)
        end

        loaded
      end)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    send(parent, {:warming_completed, loaded_count, duration_ms})
  end

  defp get_hot_machines do
    for i <- 1..10_000 do
      %{
        id: "machine_#{i}",
        status: :running,
        access_count: 1000 - i,
        last_access_at: System.monotonic_time(:millisecond)
      }
    end
  end

  defp preload_batch(machines) do
    Enum.each(machines, fn machine ->
      ttl_ms = calculate_ttl(machine.access_count)

      Orchestrator.Cache.QueryCache.put(
        machine.id,
        machine,
        ttl_ms: ttl_ms
      )
    end)
  end

  defp calculate_ttl(access_count) do
    cond do
      access_count > 1000 -> :timer.seconds(300)
      access_count > 100 -> :timer.seconds(120)
      access_count > 10 -> :timer.seconds(60)
      true -> :timer.seconds(30)
    end
  end

  defp perform_background_refresh do
    Logger.debug("Starting background cache refresh")

    current_hot = get_hot_machines()
    current_hot_ids = MapSet.new(current_hot, & &1.id)

    cached_ids = MapSet.new(for i <- 1..10_000, do: "machine_#{i}")

    cold_in_cache = MapSet.difference(cached_ids, current_hot_ids)

    cold_count = MapSet.size(cold_in_cache)

    Enum.each(cold_in_cache, fn machine_id ->
      Orchestrator.Cache.QueryCache.delete(machine_id)
    end)

    new_hot_ids = MapSet.difference(current_hot_ids, cached_ids)

    new_hot_machines =
      current_hot
      |> Enum.filter(fn m -> MapSet.member?(new_hot_ids, m.id) end)
      |> Enum.take(1000)

    preload_batch(new_hot_machines)

    new_hot_count = length(new_hot_machines)

    Logger.info("Background cache refresh completed",
      evicted: cold_count,
      loaded: new_hot_count
    )

    :telemetry.execute(
      [:orchestrator, :cache_warmer, :refresh],
      %{evicted: cold_count, loaded: new_hot_count},
      %{}
    )
  end
end
