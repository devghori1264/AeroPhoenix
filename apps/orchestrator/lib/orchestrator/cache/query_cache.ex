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
    name = Keyword.get(opts, :name, :query_cache)
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    default_ttl = Keyword.get(opts, :default_ttl_ms, @default_ttl_ms)

    access_table = Module.concat(name, :access)
    config_table = Module.concat(name, :config)

    :ets.new(name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(access_table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(config_table, [:set, :public, :named_table])
    :ets.insert(config_table, {:max_size, max_size})
    :ets.insert(config_table, {:default_ttl_ms, default_ttl})

    spawn_link(fn -> cleanup_loop(name) end)

    Logger.info("QueryCache initialized",
      name: name,
      max_size: max_size,
      default_ttl_ms: default_ttl
    )

    :ok
  end

  @spec get(atom(), cache_key()) :: {:ok, cache_value()} | :not_found
  def get(name, key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(name, key) do
      [{^key, entry}] ->
        if entry.expires_at > now do
          record_access_internal(name, key, now)
          {:ok, entry.data}
        else
          :ets.delete(name, key)
          :not_found
        end

      [] ->
        :not_found
    end
  end

  @spec put(atom(), cache_key(), cache_value(), keyword()) :: :ok
  def put(name, key, value, opts \\ []) do
    now = System.monotonic_time(:millisecond)

    ttl_ms =
      case Keyword.get(opts, :ttl_ms) do
        nil ->
          access_count = get_access_count_internal(name, key)
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

    cache_size = :ets.info(name, :size)
    config_table = Module.concat(name, :config)
    [{:max_size, max_size}] = :ets.lookup(config_table, :max_size)

    if cache_size >= max_size do
      evict_lru_batch(name)
    end

    :ets.insert(name, {key, entry})

    :ok
  end

  @spec delete(atom(), cache_key()) :: :ok
  def delete(name, key) do
    access_table = Module.concat(name, :access)
    :ets.delete(name, key)
    :ets.delete(access_table, key)
    :ok
  end

  @spec record_access(atom(), cache_key()) :: :ok
  def record_access(name, key) do
    record_access_internal(name, key, System.monotonic_time(:millisecond))
  end

  @spec get_access_count(atom(), cache_key()) :: non_neg_integer()
  def get_access_count(name, key) do
    get_access_count_internal(name, key)
  end

  @spec stats(atom()) :: map()
  def stats(name) do
    size = :ets.info(name, :size)
    config_table = Module.concat(name, :config)
    [{:max_size, max_size}] = :ets.lookup(config_table, :max_size)

    now = System.monotonic_time(:millisecond)

    oldest_age_ms =
      case :ets.select(name, [{{:"$1", :"$2"}, [], [:"$2"]}], 1) do
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

  defp record_access_internal(name, key, now) do
    access_table = Module.concat(name, :access)
    :ets.update_counter(access_table, key, {2, 1}, {key, 0})

    case :ets.lookup(name, key) do
      [{^key, entry}] ->
        updated_entry = %{entry | last_access_at: now, access_count: entry.access_count + 1}
        :ets.insert(name, {key, updated_entry})

      [] ->
        :ok
    end
  end

  defp get_access_count_internal(name, key) do
    access_table = Module.concat(name, :access)

    case :ets.lookup(access_table, key) do
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

  defp evict_lru_batch(name) do
    all_entries =
      :ets.select(name, [
        {{:"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
      ])

    sorted_entries = Enum.sort_by(all_entries, fn {_key, entry} -> entry.last_access_at end)

    evict_count = max(1, round(length(sorted_entries) * @eviction_batch_pct))

    entries_to_evict = Enum.take(sorted_entries, evict_count)

    access_table = Module.concat(name, :access)

    Enum.each(entries_to_evict, fn {key, _entry} ->
      :ets.delete(name, key)
      :ets.delete(access_table, key)
    end)

    :telemetry.execute(
      [:orchestrator, :cache, :eviction],
      %{count: evict_count},
      %{reason: :lru, cache: name}
    )

    Logger.debug("Evicted LRU entries", count: evict_count, cache: name)
  end

  defp cleanup_loop(name) do
    Process.sleep(:timer.seconds(10))

    now = System.monotonic_time(:millisecond)

    expired_keys =
      :ets.select(name, [
        {{:"$1", :"$2"}, [{:<, {:map_get, :expires_at, :"$2"}, now}], [:"$1"]}
      ])

    access_table = Module.concat(name, :access)

    Enum.each(expired_keys, fn key ->
      :ets.delete(name, key)
      :ets.delete(access_table, key)
    end)

    if length(expired_keys) > 0 do
      Logger.debug("Cleaned up expired entries", count: length(expired_keys), cache: name)
    end

    cleanup_loop(name)
  end
end
