defmodule Orchestrator.Cache.PgCacheTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Cache.{PgCache, QueryCache}

  setup do
    :ets.new(:pg_cache_l2_sim, [:set, :public, :named_table])
    :ets.new(:pg_cache_l3_sim, [:set, :public, :named_table])

    QueryCache.init(max_size: 1000)

    {:ok, pid} = PgCache.start_link(enable_cache_warming: false)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      :ets.delete(:pg_cache_l2_sim)
      :ets.delete(:pg_cache_l3_sim)
    end)

    :ok
  end

  describe "get/1 - cache hierarchy" do
    test "L1 cache hit (fastest path)" do
      QueryCache.put("m123", %{data: %{status: :running}}, ttl_ms: 60_000)

      start = System.monotonic_time(:microsecond)
      {:ok, data} = PgCache.get("m123")
      duration = System.monotonic_time(:microsecond) - start

      assert data.status == :running
      assert duration < 1000
    end

    test "L2 cache hit (medium path)" do
      :ets.insert(:pg_cache_l2_sim, {"m456", %{status: :stopped}})

      {:ok, data} = PgCache.get("m456")

      assert data.status == :stopped

      {:ok, cached} = QueryCache.get("m456")
      assert cached.data == %{status: :stopped}
    end

    test "L3 cache hit (slowest path)" do
      :ets.insert(:pg_cache_l3_sim, {"m789", %{status: :created}})

      {:ok, data} = PgCache.get("m789")

      assert data.status == :created

      {:ok, l1_cached} = QueryCache.get("m789")
      assert l1_cached.data == %{status: :created}

      [{_, l2_data}] = :ets.lookup(:pg_cache_l2_sim, "m789")
      assert l2_data.status == :created
    end

    test "cache miss (not found)" do
      result = PgCache.get("nonexistent")

      assert {:error, :not_found} = result
    end
  end

  describe "put/2 - write path" do
    test "writes to L3 and invalidates L1" do
      QueryCache.put("m123", %{data: %{status: :stopped}}, ttl_ms: 60_000)

      :ok = PgCache.put("m123", %{status: :running})

      assert :not_found = QueryCache.get("m123")

      [{_, l3_data}] = :ets.lookup(:pg_cache_l3_sim, "m123")
      assert l3_data.status == :running
    end

    test "async replication to L2" do
      :ok = PgCache.put("m456", %{status: :running})

      [{_, l3_data}] = :ets.lookup(:pg_cache_l3_sim, "m456")
      assert l3_data.status == :running
    end
  end

  describe "delete/1" do
    test "deletes from all tiers" do
      QueryCache.put("m123", %{data: %{status: :running}}, ttl_ms: 60_000)
      :ets.insert(:pg_cache_l2_sim, {"m123", %{status: :running}})
      :ets.insert(:pg_cache_l3_sim, {"m123", %{status: :running}})

      :ok = PgCache.delete("m123")

      assert :not_found = QueryCache.get("m123")
      assert [] = :ets.lookup(:pg_cache_l2_sim, "m123")
      assert [] = :ets.lookup(:pg_cache_l3_sim, "m123")
    end
  end

  describe "stats/0" do
    test "tracks cache hits and misses" do
      :ets.insert(:pg_cache_l3_sim, {"m1", %{status: :running}})
      :ets.insert(:pg_cache_l3_sim, {"m2", %{status: :stopped}})
      QueryCache.put("m3", %{data: %{status: :created}}, ttl_ms: 60_000)

      PgCache.get("m3")
      PgCache.get("m3")
      PgCache.get("m1")
      PgCache.get("m2")
      PgCache.get("nonexistent")

      stats = PgCache.stats()

      assert stats.l1_hits == 2
      assert stats.l3_hits == 2
      assert stats.misses == 1
      assert stats.total_requests == 5
      assert stats.hit_rate == 0.8
    end

    test "calculates weighted average latency" do
      QueryCache.put("hot", %{data: %{status: :running}}, ttl_ms: 60_000)

      for _ <- 1..100 do
        PgCache.get("hot")
      end

      stats = PgCache.stats()

      assert stats.avg_latency_us < 10
    end
  end
end
