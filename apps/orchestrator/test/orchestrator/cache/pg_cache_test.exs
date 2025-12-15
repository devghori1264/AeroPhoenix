defmodule Orchestrator.Cache.PgCacheTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Cache.{PgCache, QueryCache}

  setup do
    unique_suffix = :erlang.unique_integer([:positive])
    query_cache_name = Module.concat(QueryCache, :"Test#{unique_suffix}")
    l2_name = Module.concat(PgCache, :"L2Test#{unique_suffix}")
    l3_name = Module.concat(PgCache, :"L3Test#{unique_suffix}")

    :ets.new(l2_name, [:set, :public, :named_table])
    :ets.new(l3_name, [:set, :public, :named_table])

    {:ok, pid} =
      PgCache.start_link(
        name: Module.concat(PgCache, :"Test#{unique_suffix}"),
        enable_cache_warming: false,
        query_cache_name: query_cache_name,
        l2_name: l2_name,
        l3_name: l3_name
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      try do
        :ets.delete(l2_name)
      rescue
        _ -> :ok
      end

      try do
        :ets.delete(l3_name)
      rescue
        _ -> :ok
      end
    end)

    {:ok, pid: pid, query_cache_name: query_cache_name, l2_name: l2_name, l3_name: l3_name}
  end

  describe "get/1 - cache hierarchy" do
    test "L1 cache hit (fastest path)", %{pid: pid, query_cache_name: qc_name} do
      QueryCache.put(qc_name, "m123", %{data: %{status: :running}}, ttl_ms: 60_000)

      start = System.monotonic_time(:microsecond)
      {:ok, data} = PgCache.get(pid, "m123")
      duration = System.monotonic_time(:microsecond) - start

      assert data.status == :running
      assert duration < 1000
    end

    test "L2 cache hit (medium path)", %{pid: pid, query_cache_name: qc_name, l2_name: l2_name} do
      :ets.insert(l2_name, {"m456", %{status: :stopped}})

      {:ok, data} = PgCache.get(pid, "m456")

      assert data.status == :stopped

      {:ok, cached} = QueryCache.get(qc_name, "m456")
      assert cached.data == %{status: :stopped}
    end

    test "L3 cache hit (slowest path)", %{
      pid: pid,
      query_cache_name: qc_name,
      l2_name: l2_name,
      l3_name: l3_name
    } do
      :ets.insert(l3_name, {"m789", %{status: :created}})

      {:ok, data} = PgCache.get(pid, "m789")

      assert data.status == :created

      {:ok, l1_cached} = QueryCache.get(qc_name, "m789")
      assert l1_cached.data == %{status: :created}

      [{_, l2_data}] = :ets.lookup(l2_name, "m789")
      assert l2_data.status == :created
    end

    test "cache miss (not found)", %{pid: pid} do
      result = PgCache.get(pid, "nonexistent")

      assert {:error, :not_found} = result
    end
  end

  describe "put/2 - write path" do
    test "writes to L3 and invalidates L1", %{
      pid: pid,
      query_cache_name: qc_name,
      l3_name: l3_name
    } do
      QueryCache.put(qc_name, "m123", %{data: %{status: :stopped}}, ttl_ms: 60_000)

      :ok = PgCache.put(pid, "m123", %{status: :running})

      assert :not_found = QueryCache.get(qc_name, "m123")

      [{_, l3_data}] = :ets.lookup(l3_name, "m123")
      assert l3_data.status == :running
    end

    test "async replication to L2", %{pid: pid, l3_name: l3_name} do
      :ok = PgCache.put(pid, "m456", %{status: :running})

      [{_, l3_data}] = :ets.lookup(l3_name, "m456")
      assert l3_data.status == :running
    end
  end

  describe "delete/1" do
    test "deletes from all tiers", %{
      pid: pid,
      query_cache_name: qc_name,
      l2_name: l2_name,
      l3_name: l3_name
    } do
      QueryCache.put(qc_name, "m123", %{data: %{status: :running}}, ttl_ms: 60_000)
      :ets.insert(l2_name, {"m123", %{status: :running}})
      :ets.insert(l3_name, {"m123", %{status: :running}})

      :ok = PgCache.delete(pid, "m123")

      assert :not_found = QueryCache.get(qc_name, "m123")
      assert [] = :ets.lookup(l2_name, "m123")
      assert [] = :ets.lookup(l3_name, "m123")
    end
  end

  describe "stats/0" do
    test "tracks cache hits and misses", %{pid: pid, query_cache_name: qc_name, l3_name: l3_name} do
      :ets.insert(l3_name, {"m1", %{status: :running}})
      :ets.insert(l3_name, {"m2", %{status: :stopped}})
      QueryCache.put(qc_name, "m3", %{data: %{status: :created}}, ttl_ms: 60_000)

      PgCache.get(pid, "m3")
      PgCache.get(pid, "m3")
      PgCache.get(pid, "m1")
      PgCache.get(pid, "m2")
      PgCache.get(pid, "nonexistent")

      stats = PgCache.stats(pid)

      assert stats.l1_hits == 2
      assert stats.l3_hits == 2
      assert stats.misses == 1
      assert stats.total_requests == 5
      assert stats.hit_rate == 0.8
    end

    test "calculates weighted average latency", %{pid: pid, query_cache_name: qc_name} do
      QueryCache.put(qc_name, "hot", %{data: %{status: :running}}, ttl_ms: 60_000)

      for _ <- 1..100 do
        PgCache.get(pid, "hot")
      end

      stats = PgCache.stats(pid)

      assert stats.avg_latency_us < 10
    end
  end
end
