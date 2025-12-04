defmodule Orchestrator.Cache.PgCache do
  use GenServer
  require Logger

  alias Orchestrator.Cache.{QueryCache, ReplicationBuffer, CacheWarmer}
  alias Orchestrator.Replication.CRDT.VectorClock

  @type machine_id :: String.t()
  @type cache_entry :: %{
          data: term(),
          hlc: pos_integer(),
          vector_clock: VectorClock.t(),
          access_count: non_neg_integer(),
          last_access_at: integer()
        }

  @type state :: %{
          replication_buffer: pid(),
          cache_warmer: pid() | nil,
          query_cache_name: atom(),
          l2_name: atom(),
          l3_name: atom(),
          stats: %{
            l1_hits: non_neg_integer(),
            l2_hits: non_neg_integer(),
            l3_hits: non_neg_integer(),
            misses: non_neg_integer(),
            evictions: non_neg_integer()
          }
        }

  @l1_cache_size 100_000
  @default_ttl_seconds 60
  @replication_debounce_ms 100
  @bloom_filter_size 1_000_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get(GenServer.server(), machine_id()) :: {:ok, term()} | {:error, :not_found}
  def get(server \\ __MODULE__, machine_id) do
    GenServer.call(server, {:get, machine_id})
  end

  @spec put(GenServer.server(), machine_id(), term()) :: :ok | {:error, term()}
  def put(server \\ __MODULE__, machine_id, data) do
    GenServer.call(server, {:put, machine_id, data})
  end

  @spec delete(GenServer.server(), machine_id()) :: :ok
  def delete(server \\ __MODULE__, machine_id) do
    GenServer.call(server, {:delete, machine_id})
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    enable_warming = Keyword.get(opts, :enable_cache_warming, true)
    l1_size = Keyword.get(opts, :l1_cache_size, @l1_cache_size)
    debounce_ms = Keyword.get(opts, :replication_debounce_ms, @replication_debounce_ms)

    name = Keyword.get(opts, :query_cache_name, :query_cache)
    l2_name = Keyword.get(opts, :l2_name, :pg_cache_l2_sim)
    l3_name = Keyword.get(opts, :l3_name, :pg_cache_l3_sim)

    QueryCache.init(name: name, max_size: l1_size, bloom_filter_size: @bloom_filter_size)

    {:ok, buffer_pid} = ReplicationBuffer.start_link(debounce_ms: debounce_ms)

    warmer_pid =
      if enable_warming do
        {:ok, pid} = CacheWarmer.start_link(query_cache_name: name)
        CacheWarmer.warm_cache(pid)
        pid
      else
        nil
      end

    state = %{
      replication_buffer: buffer_pid,
      cache_warmer: warmer_pid,
      query_cache_name: name,
      l2_name: l2_name,
      l3_name: l3_name,
      stats: %{
        l1_hits: 0,
        l2_hits: 0,
        l3_hits: 0,
        misses: 0,
        evictions: 0
      }
    }

    Logger.info("PgCache started",
      l1_size: l1_size,
      cache_warming: enable_warming,
      query_cache_name: name
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:get, machine_id}, _from, state) do
    start_time = System.monotonic_time(:microsecond)

    result =
      case get_from_l1(state.query_cache_name, machine_id) do
        {:ok, data} ->
          new_state = update_stats(state, :l1_hit)
          emit_metric(:l1_hit, machine_id, start_time)
          {:reply, {:ok, data}, new_state}

        :miss ->
          case get_from_l2(state.l2_name, machine_id) do
            {:ok, data} ->
              populate_l1(state.query_cache_name, machine_id, data)
              new_state = update_stats(state, :l2_hit)
              emit_metric(:l2_hit, machine_id, start_time)
              {:reply, {:ok, data}, new_state}

            :miss ->
              case get_from_l3(state.l3_name, machine_id) do
                {:ok, data} ->
                  populate_l2(state.l2_name, machine_id, data)
                  populate_l1(state.query_cache_name, machine_id, data)
                  new_state = update_stats(state, :l3_hit)
                  emit_metric(:l3_hit, machine_id, start_time)
                  {:reply, {:ok, data}, new_state}

                :not_found ->
                  new_state = update_stats(state, :miss)
                  emit_metric(:miss, machine_id, start_time)
                  {:reply, {:error, :not_found}, new_state}
              end
          end
      end

    result
  end

  @impl true
  def handle_call({:put, machine_id, data}, _from, state) do
    case write_to_l3(state.l3_name, machine_id, data) do
      :ok ->
        invalidate_l1(state.query_cache_name, machine_id)

        ReplicationBuffer.enqueue(state.replication_buffer, machine_id, data)

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:delete, machine_id}, _from, state) do
    invalidate_l1(state.query_cache_name, machine_id)
    delete_from_l2(state.l2_name, machine_id)
    delete_from_l3(state.l3_name, machine_id)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total_requests =
      state.stats.l1_hits + state.stats.l2_hits + state.stats.l3_hits + state.stats.misses

    hit_rate =
      if total_requests > 0 do
        (state.stats.l1_hits + state.stats.l2_hits + state.stats.l3_hits) / total_requests
      else
        0.0
      end

    l1_weight = if total_requests > 0, do: state.stats.l1_hits / total_requests, else: 0.0
    l2_weight = if total_requests > 0, do: state.stats.l2_hits / total_requests, else: 0.0
    l3_weight = if total_requests > 0, do: state.stats.l3_hits / total_requests, else: 0.0

    avg_latency_us = l1_weight * 3 + l2_weight * 30_000 + l3_weight * 15_000

    stats =
      Map.merge(state.stats, %{
        total_requests: total_requests,
        hit_rate: Float.round(hit_rate, 4),
        avg_latency_us: round(avg_latency_us),
        l1_hit_rate: if(total_requests > 0, do: state.stats.l1_hits / total_requests, else: 0.0),
        l2_hit_rate: if(total_requests > 0, do: state.stats.l2_hits / total_requests, else: 0.0),
        l3_hit_rate: if(total_requests > 0, do: state.stats.l3_hits / total_requests, else: 0.0)
      })

    {:reply, stats, state}
  end

  defp get_from_l1(name, machine_id) do
    case QueryCache.get(name, machine_id) do
      {:ok, entry} ->
        QueryCache.record_access(name, machine_id)
        {:ok, entry.data}

      :not_found ->
        :miss
    end
  end

  defp get_from_l2(l2_name, machine_id) do
    case :ets.lookup(l2_name, machine_id) do
      [{^machine_id, data}] -> {:ok, data}
      [] -> :miss
    end
  end

  defp get_from_l3(l3_name, machine_id) do
    case :ets.lookup(l3_name, machine_id) do
      [{^machine_id, data}] -> {:ok, data}
      [] -> :not_found
    end
  end

  defp populate_l1(name, machine_id, data) do
    access_count = QueryCache.get_access_count(name, machine_id)
    ttl_ms = adaptive_ttl(access_count)

    QueryCache.put(name, machine_id, %{data: data}, ttl_ms: ttl_ms)
  end

  defp populate_l2(l2_name, machine_id, data) do
    :ets.insert(l2_name, {machine_id, data})
  end

  defp invalidate_l1(name, machine_id) do
    QueryCache.delete(name, machine_id)
  end

  defp write_to_l3(l3_name, machine_id, data) do
    :ets.insert(l3_name, {machine_id, data})
    :ok
  end

  defp delete_from_l2(l2_name, machine_id) do
    :ets.delete(l2_name, machine_id)
  end

  defp delete_from_l3(l3_name, machine_id) do
    :ets.delete(l3_name, machine_id)
  end

  defp adaptive_ttl(access_count_per_minute) do
    cond do
      access_count_per_minute > 1000 -> :timer.seconds(300)
      access_count_per_minute > 100 -> :timer.seconds(120)
      access_count_per_minute > 10 -> :timer.seconds(@default_ttl_seconds)
      access_count_per_minute > 1 -> :timer.seconds(30)
      true -> :timer.seconds(5)
    end
  end

  defp update_stats(state, metric) do
    case metric do
      :l1_hit -> put_in(state, [:stats, :l1_hits], state.stats.l1_hits + 1)
      :l2_hit -> put_in(state, [:stats, :l2_hits], state.stats.l2_hits + 1)
      :l3_hit -> put_in(state, [:stats, :l3_hits], state.stats.l3_hits + 1)
      :miss -> put_in(state, [:stats, :misses], state.stats.misses + 1)
      :eviction -> put_in(state, [:stats, :evictions], state.stats.evictions + 1)
    end
  end

  defp emit_metric(level, machine_id, start_time) do
    latency_us = System.monotonic_time(:microsecond) - start_time

    :telemetry.execute(
      [:orchestrator, :cache, :read],
      %{latency_us: latency_us},
      %{level: level, machine_id: machine_id}
    )
  end
end
