defmodule Orchestrator.Metrics.LatencyTrackerTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Metrics.LatencyTracker

  setup _context do
    try do
      :ets.delete_all_objects(:latency_histograms)
      :ets.delete_all_objects(:latency_windows)

      if :ets.info(:hedged_request_metrics) != :undefined do
        :ets.delete_all_objects(:hedged_request_metrics)
      end
    rescue
      ArgumentError -> :ok
    end

    Process.sleep(5)

    LatencyTracker.reset("test_metric")
    :ok
  end

  describe "record/2" do
    test "records latency observation" do
      LatencyTracker.record("test_metric", 100_000)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.count == 1
      assert stats.sum == 100_000
      assert stats.min == 100_000
      assert stats.max == 100_000
    end

    test "records multiple observations" do
      LatencyTracker.record("test_metric", 50_000)
      LatencyTracker.record("test_metric", 100_000)
      LatencyTracker.record("test_metric", 150_000)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.count == 3
      assert stats.sum == 300_000
      assert stats.min == 50_000
      assert stats.max == 150_000
    end

    test "clamps values to trackable range" do
      LatencyTracker.record("test_metric", 999_999_999_999)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.max <= 3_600_000_000
    end
  end

  describe "percentile/2" do
    test "calculates P50 (median)" do
      for i <- 1..100 do
        LatencyTracker.record("test_metric", i * 1000)
      end

      {:ok, p50} = LatencyTracker.percentile("test_metric", 50.0)

      assert p50 >= 25_000
      assert p50 <= 75_000
    end

    test "calculates P99" do
      for i <- 1..100 do
        LatencyTracker.record("test_metric", i * 1000)
      end

      {:ok, p99} = LatencyTracker.percentile("test_metric", 99.0)

      assert p99 >= 65_000
      assert p99 <= 131_000
    end

    test "returns error for non-existent metric" do
      result = LatencyTracker.percentile("nonexistent", 50.0)

      assert result == {:error, :not_found}
    end

    test "P99 captures tail latency" do
      for _ <- 1..99 do
        LatencyTracker.record("test_metric", 10_000)
      end

      LatencyTracker.record("test_metric", 1_000_000)
      LatencyTracker.record("test_metric", 1_000_000)

      Process.sleep(50)

      {:ok, p50} = LatencyTracker.percentile("test_metric", 50.0)
      {:ok, p99} = LatencyTracker.percentile("test_metric", 99.0)

      assert p50 <= 20_000

      assert p99 >= 500_000
    end
  end

  describe "percentiles/2" do
    test "calculates multiple percentiles efficiently" do
      for i <- 1..1000 do
        LatencyTracker.record("test_metric", i * 10000)
      end

      {:ok, percentiles} = LatencyTracker.percentiles("test_metric", [50.0, 95.0, 99.0, 99.9])

      assert Map.has_key?(percentiles, :p50)
      assert Map.has_key?(percentiles, :p95)
      assert Map.has_key?(percentiles, :p99)
      assert Map.has_key?(percentiles, :p999)

      assert percentiles.p50 < percentiles.p95
      assert percentiles.p95 <= percentiles.p99
      assert percentiles.p99 <= percentiles.p999
    end

    test "returns error for non-existent metric" do
      result = LatencyTracker.percentiles("nonexistent", [50.0, 99.0])

      assert result == {:error, :not_found}
    end
  end

  describe "windowed_percentiles/2" do
    test "calculates percentiles across time windows" do
      for i <- 1..100 do
        LatencyTracker.record("test_metric", i * 1000)
      end

      {:ok, windowed} = LatencyTracker.windowed_percentiles("test_metric", 99.0)

      assert Map.has_key?(windowed, :window_1min)
      assert Map.has_key?(windowed, :window_5min)
      assert Map.has_key?(windowed, :window_1hr)

      assert windowed.window_1min > 0
      assert windowed.window_5min > 0
      assert windowed.window_1hr > 0
    end

    test "windows reflect recent vs historical behavior" do
      for _ <- 1..100 do
        LatencyTracker.record("test_metric", 10_000)
      end

      {:ok, windowed_before} = LatencyTracker.windowed_percentiles("test_metric", 99.0)

      for _ <- 1..10 do
        LatencyTracker.record("test_metric", 100_000)
      end

      {:ok, windowed_after} = LatencyTracker.windowed_percentiles("test_metric", 99.0)

      assert windowed_after.window_1min >= windowed_before.window_1min
    end
  end

  describe "stats/1" do
    test "returns comprehensive statistics" do
      LatencyTracker.record("test_metric", 50_000)
      LatencyTracker.record("test_metric", 100_000)
      LatencyTracker.record("test_metric", 150_000)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.count == 3
      assert stats.min == 50_000
      assert stats.max == 150_000
      assert stats.sum == 300_000
      assert stats.mean == 100_000
    end

    test "returns error for non-existent metric" do
      result = LatencyTracker.stats("nonexistent")

      assert result == {:error, :not_found}
    end

    test "mean is calculated correctly" do
      LatencyTracker.record("test_metric", 10_000)
      LatencyTracker.record("test_metric", 20_000)
      LatencyTracker.record("test_metric", 30_000)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.mean == 20_000
    end
  end

  describe "reset/1" do
    test "clears histogram for metric" do
      LatencyTracker.record("test_metric", 100_000)

      {:ok, stats_before} = LatencyTracker.stats("test_metric")
      assert stats_before.count == 1

      LatencyTracker.reset("test_metric")

      result = LatencyTracker.stats("test_metric")
      assert result == {:error, :not_found}
    end

    test "reset doesn't affect other metrics" do
      LatencyTracker.record("metric1", 100_000)
      LatencyTracker.record("metric2", 200_000)

      LatencyTracker.reset("metric1")

      assert LatencyTracker.stats("metric1") == {:error, :not_found}
      assert {:ok, _stats} = LatencyTracker.stats("metric2")
    end
  end

  describe "concurrent safety" do
    test "handles concurrent recordings" do
      tasks =
        for i <- 1..1000 do
          Task.async(fn ->
            LatencyTracker.record("test_metric", i * 1000)
          end)
        end

      Task.await_many(tasks)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.count == 1000
    end

    test "percentile calculation is thread-safe" do
      Task.async(fn ->
        for i <- 1..100 do
          LatencyTracker.record("test_metric", i * 1000)
          Process.sleep(1)
        end
      end)

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            LatencyTracker.percentile("test_metric", 99.0)
          end)
        end

      results = Task.await_many(tasks)

      assert Enum.all?(results, fn result ->
               match?({:ok, _}, result) or match?({:error, :not_found}, result)
             end)
    end
  end

  describe "edge cases" do
    test "handles single observation" do
      LatencyTracker.record("test_metric", 100_000)

      {:ok, p50} = LatencyTracker.percentile("test_metric", 50.0)
      {:ok, p99} = LatencyTracker.percentile("test_metric", 99.0)

      assert p50 == p99
    end

    test "handles very small latencies (1μs)" do
      LatencyTracker.record("test_metric", 1)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.min == 1
    end

    test "handles very large latencies (1 hour)" do
      LatencyTracker.record("test_metric", 3_600_000_000)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.max == 3_600_000_000
    end

    test "handles zero latency" do
      LatencyTracker.record("test_metric", 0)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.min == 1
    end

    test "P0 percentile" do
      for i <- 1..100 do
        LatencyTracker.record("test_metric", i * 1000)
      end

      {:ok, p0} = LatencyTracker.percentile("test_metric", 0.0)

      assert p0 <= 10_000
    end

    test "P100 percentile" do
      for i <- 1..100 do
        LatencyTracker.record("test_metric", i * 1000)
      end

      {:ok, p100} = LatencyTracker.percentile("test_metric", 100.0)

      assert p100 >= 50_000
    end
  end

  describe "performance benchmarks" do
    @tag :performance
    test "records 10,000 observations efficiently" do
      start_time = System.monotonic_time(:microsecond)

      for i <- 1..10_000 do
        LatencyTracker.record("test_metric", i * 1000)
      end

      end_time = System.monotonic_time(:microsecond)
      duration_ms = div(end_time - start_time, 1000)

      assert duration_ms < 1000
    end

    @tag :performance
    test "percentile calculation scales with observations" do
      for i <- 1..10_000 do
        LatencyTracker.record("test_metric", i * 1000)
      end

      start_time = System.monotonic_time(:microsecond)
      {:ok, _p99} = LatencyTracker.percentile("test_metric", 99.0)
      end_time = System.monotonic_time(:microsecond)

      duration_ms = div(end_time - start_time, 1000)

      assert duration_ms < 50
    end

    @tag :performance
    test "multiple percentiles calculated together" do
      for i <- 1..10_000 do
        LatencyTracker.record("test_metric", i * 1000)
      end

      start_time = System.monotonic_time(:microsecond)

      {:ok, _percentiles} =
        LatencyTracker.percentiles("test_metric", [50.0, 95.0, 99.0, 99.9, 99.99])

      end_time = System.monotonic_time(:microsecond)

      duration_ms = div(end_time - start_time, 1000)

      assert duration_ms < 100
    end
  end

  describe "HDR histogram accuracy" do
    test "maintains precision across dynamic range" do
      latencies = [
        1,
        100,
        10_000,
        1_000_000,
        60_000_000,
        3_600_000_000
      ]

      Enum.each(latencies, fn latency ->
        LatencyTracker.record("test_metric", latency)
      end)

      {:ok, stats} = LatencyTracker.stats("test_metric")

      assert stats.min == 1
      assert stats.max == 3_600_000_000
      assert stats.count == 6
    end

    test "percentiles reflect actual distribution" do
      for _ <- 1..90 do
        LatencyTracker.record("test_metric", 10_000)
      end

      for _ <- 1..10 do
        LatencyTracker.record("test_metric", 100_000)
      end

      {:ok, percentiles} = LatencyTracker.percentiles("test_metric", [50.0, 90.0, 95.0])

      assert percentiles.p50 <= 20_000

      assert percentiles.p95 >= 50_000
    end
  end
end
