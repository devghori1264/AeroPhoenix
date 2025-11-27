defmodule Orchestrator.Cache.QueryCache do
  require Logger

  @type cache_key :: term()
  @type cache_value :: term()
  @type cache_entry :: %{
          data: cache_value(),
          access_count: non_neg_integer(),
          inserted_at: integer(),
          last_access_at: integer(),
          expires_at: integer()
        }

  @default_max_size 100_000
  @default_ttl_ms :timer.seconds(60)
  @eviction_batch_pct 0.10
  @spec init(keyword()) :: :ok
  def init(opts \\ []) do
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    default_ttl = Keyword.get(opts, :default_ttl_ms, @default_ttl_ms)

    :ets.new(:query_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(:query_cache_access, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(:query_cache_inflight, [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    :ets.new(:query_cache_config, [:set, :public, :named_table])
    :ets.insert(:query_cache_config, {:max_size, max_size})
    :ets.insert(:query_cache_config, {:default_ttl_ms, default_ttl})

    spawn_link(fn -> cleanup_loop() end)

    Logger.info("QueryCache initialized", max_size: max_size, default_ttl_ms: default_ttl)
    :ok
  end

  @spec get(cache_key()) :: {:ok, cache_value()} | :not_found
  def get(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(:query_cache, key) do
      [{^key, entry}] ->
        if entry.expires_at > now do
          record_access_internal(key, now)
          {:ok, entry.data}
        else
          :ets.delete(:query_cache, key)
          :not_found
        end

      [] ->
        :not_found
    end
  end

  @spec put(cache_key(), cache_value(), keyword()) :: :ok
  def put(key, value, opts \\ []) do
    now = System.monotonic_time(:millisecond)

    ttl_ms =
      case Keyword.get(opts, :ttl_ms) do
        nil ->
          access_count = get_access_count_internal(key)
          calculate_adaptive_ttl(access_count)

        explicit_ttl ->
          explicit_ttl
      end

    entry = %{
      data: value,
      access_count: 0,
      inserted_at: now,
      last_access_at: now,
      expires_at: now + ttl_ms
    }

    cache_size = :ets.info(:query_cache, :size)
    [{:max_size, max_size}] = :ets.lookup(:query_cache_config, :max_size)

    if cache_size >= max_size do
      evict_lru_batch()
    end

    :ets.insert(:query_cache, {key, entry})

    :ok
  end

  @spec delete(cache_key()) :: :ok
  def delete(key) do
    :ets.delete(:query_cache, key)
    :ets.delete(:query_cache_access, key)
    :ok
  end

  @spec record_access(cache_key()) :: :ok
  def record_access(key) do
    record_access_internal(key, System.monotonic_time(:millisecond))
  end

  @spec get_access_count(cache_key()) :: non_neg_integer()
  def get_access_count(key) do
    get_access_count_internal(key)
  end

  @spec stats() :: map()
  def stats do
    size = :ets.info(:query_cache, :size)
    [{:max_size, max_size}] = :ets.lookup(:query_cache_config, :max_size)

    now = System.monotonic_time(:millisecond)

    oldest_age_ms =
      case :ets.select(:query_cache, [{{:"$1", :"$2"}, [], [:"$2"]}], 1) do
        {[entry], _continuation} ->
          now - entry.inserted_at

        :"$end_of_table" ->
          0
      end

    %{
      size: size,
      max_size: max_size,
      utilization_pct: Float.round(size / max_size * 100, 2),
      oldest_entry_age_ms: oldest_age_ms
    }
  end

  defp record_access_internal(key, now) do
    :ets.update_counter(:query_cache_access, key, {2, 1}, {key, 0})

    case :ets.lookup(:query_cache, key) do
      [{^key, entry}] ->
        updated_entry = %{entry | last_access_at: now, access_count: entry.access_count + 1}
        :ets.insert(:query_cache, {key, updated_entry})

      [] ->
        :ok
    end
  end

  defp get_access_count_internal(key) do
    case :ets.lookup(:query_cache_access, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  defp calculate_adaptive_ttl(access_count) do
    cond do
      access_count > 1000 -> :timer.seconds(300)
      access_count > 100 -> :timer.seconds(120)
      access_count > 10 -> :timer.seconds(60)
      access_count > 1 -> :timer.seconds(30)
      true -> :timer.seconds(5)
    end
  end

  defp evict_lru_batch do
    all_entries =
      :ets.select(:query_cache, [
        {{:"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
      ])

    sorted_entries = Enum.sort_by(all_entries, fn {_key, entry} -> entry.last_access_at end)

    evict_count = max(1, round(length(sorted_entries) * @eviction_batch_pct))

    entries_to_evict = Enum.take(sorted_entries, evict_count)

    Enum.each(entries_to_evict, fn {key, _entry} ->
      :ets.delete(:query_cache, key)
      :ets.delete(:query_cache_access, key)
    end)

    :telemetry.execute(
      [:orchestrator, :cache, :eviction],
      %{count: evict_count},
      %{reason: :lru}
    )

    Logger.debug("Evicted LRU entries", count: evict_count)
  end

  defp cleanup_loop do
    Process.sleep(:timer.seconds(10))

    now = System.monotonic_time(:millisecond)

    expired_keys =
      :ets.select(:query_cache, [
        {{:"$1", :"$2"}, [{:<, {:map_get, :expires_at, :"$2"}, now}], [:"$1"]}
      ])

    Enum.each(expired_keys, fn key ->
      :ets.delete(:query_cache, key)
      :ets.delete(:query_cache_access, key)
    end)

    if length(expired_keys) > 0 do
      Logger.debug("Cleaned up expired entries", count: length(expired_keys))
    end

    cleanup_loop()
  end
end
