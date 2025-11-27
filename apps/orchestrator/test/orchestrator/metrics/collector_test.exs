defmodule Orchestrator.Metrics.CollectorTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Metrics.Collector

  setup do
    {:ok, pid} = Collector.start_link()

    on_exit(fn ->
      if Process.alive?(pid) do
        Collector.detach_handlers()
        Process.exit(pid, :normal)
      end

      :ets.delete_all_objects(:metrics_counters)
      :ets.delete_all_objects(:metrics_gauges)
      :ets.delete_all_objects(:metrics_histograms)
    end)

    {:ok, collector_pid: pid}
  end

  describe "increment_counter/3" do
    test "increments counter by 1" do
      Collector.increment_counter("test_counter", %{region: "iad"}, 1)

      metrics = Collector.get_metrics()
      counter = Enum.find(metrics, &(&1.name == "test_counter"))

      assert counter != nil
      assert counter.type == :counter
      assert counter.value == 1
    end

    test "increments counter by custom value" do
      Collector.increment_counter("test_counter", %{region: "iad"}, 10)

      metrics = Collector.get_metrics()
      counter = Enum.find(metrics, &(&1.name == "test_counter"))

      assert counter.value == 10
    end

    test "accumulates multiple increments" do
      Collector.increment_counter("test_counter", %{region: "iad"}, 1)
      Collector.increment_counter("test_counter", %{region: "iad"}, 2)
      Collector.increment_counter("test_counter", %{region: "iad"}, 3)

      metrics = Collector.get_metrics()
      counter = Enum.find(metrics, &(&1.name == "test_counter"))

      assert counter.value == 6
    end

    test "separate counters for different labels" do
      Collector.increment_counter("test_counter", %{region: "iad"}, 10)
      Collector.increment_counter("test_counter", %{region: "lhr"}, 20)

      metrics = Collector.get_metrics()
      counters = Enum.filter(metrics, &(&1.name == "test_counter"))

      assert length(counters) == 2

      iad_counter = Enum.find(counters, &(&1.labels.region == "iad"))
      lhr_counter = Enum.find(counters, &(&1.labels.region == "lhr"))

      assert iad_counter.value == 10
      assert lhr_counter.value == 20
    end
  end

  describe "set_gauge/3" do
    test "sets gauge to specific value" do
      Collector.set_gauge("test_gauge", %{region: "iad"}, 42)

      metrics = Collector.get_metrics()
      gauge = Enum.find(metrics, &(&1.name == "test_gauge"))

      assert gauge != nil
      assert gauge.type == :gauge
      assert gauge.value == 42
    end

    test "overwrites previous gauge value" do
      Collector.set_gauge("test_gauge", %{region: "iad"}, 10)
      Collector.set_gauge("test_gauge", %{region: "iad"}, 20)

      metrics = Collector.get_metrics()
      gauge = Enum.find(metrics, &(&1.name == "test_gauge"))

      assert gauge.value == 20
    end

    test "separate gauges for different labels" do
      Collector.set_gauge("test_gauge", %{region: "iad"}, 100)
      Collector.set_gauge("test_gauge", %{region: "lhr"}, 200)

      metrics = Collector.get_metrics()
      gauges = Enum.filter(metrics, &(&1.name == "test_gauge"))

      assert length(gauges) == 2
    end

    test "gauge can decrease" do
      Collector.set_gauge("test_gauge", %{region: "iad"}, 100)
      Collector.set_gauge("test_gauge", %{region: "iad"}, 50)

      metrics = Collector.get_metrics()
      gauge = Enum.find(metrics, &(&1.name == "test_gauge"))

      assert gauge.value == 50
    end
  end

  describe "observe_histogram/3" do
    test "records histogram observation" do
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.5)

      metrics = Collector.get_metrics()
      histogram = Enum.find(metrics, &(&1.name == "test_histogram"))

      assert histogram != nil
      assert histogram.type == :histogram
      assert histogram.count == 1
      assert histogram.sum == 0.5
    end

    test "accumulates multiple observations" do
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.1)
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.5)
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 1.0)

      metrics = Collector.get_metrics()
      histogram = Enum.find(metrics, &(&1.name == "test_histogram"))

      assert histogram.count == 3
      assert histogram.sum == 1.6
    end

    test "distributes observations into buckets" do
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.002)
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.05)
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.8)

      metrics = Collector.get_metrics()
      histogram = Enum.find(metrics, &(&1.name == "test_histogram"))

      buckets = histogram.buckets

      bucket_0_1 = Enum.find(buckets, fn {le, _count} -> le == 0.1 end)
      assert bucket_0_1 == {0.1, 2}

      bucket_1_0 = Enum.find(buckets, fn {le, _count} -> le == 1.0 end)
      assert bucket_1_0 == {1.0, 3}
    end

    test "infinity bucket contains all observations" do
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.1)
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 50.0)

      metrics = Collector.get_metrics()
      histogram = Enum.find(metrics, &(&1.name == "test_histogram"))

      infinity_bucket = Enum.find(histogram.buckets, fn {le, _count} -> le == :infinity end)
      assert infinity_bucket == {:infinity, 2}
    end
  end

  describe "get_metrics/0" do
    test "returns empty list when no metrics" do
      metrics = Collector.get_metrics()

      assert metrics == []
    end

    test "returns all metric types" do
      Collector.increment_counter("test_counter", %{}, 1)
      Collector.set_gauge("test_gauge", %{}, 42)
      Collector.observe_histogram("test_histogram", %{}, 0.5)

      metrics = Collector.get_metrics()

      assert length(metrics) == 3

      counter = Enum.find(metrics, &(&1.type == :counter))
      gauge = Enum.find(metrics, &(&1.type == :gauge))
      histogram = Enum.find(metrics, &(&1.type == :histogram))

      assert counter != nil
      assert gauge != nil
      assert histogram != nil
    end

    test "groups histograms correctly" do
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.1)
      Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.5)

      metrics = Collector.get_metrics()
      histogram = Enum.find(metrics, &(&1.name == "test_histogram"))

      assert histogram.count == 2
      assert is_list(histogram.buckets)
    end
  end

  describe "prometheus_format/0" do
    test "generates Prometheus text format" do
      Collector.increment_counter("test_counter", %{region: "iad"}, 10)

      output = Collector.prometheus_format()

      assert output =~ "# HELP test_counter"
      assert output =~ "# TYPE test_counter counter"
      assert output =~ ~r/test_counter\{region="iad"\} 10/
    end

    test "formats counter with multiple labels" do
      Collector.increment_counter("requests_total", %{method: "GET", status: "200"}, 100)

      output = Collector.prometheus_format()

      assert output =~ ~r/requests_total\{method="GET",status="200"\} 100/
    end

    test "formats gauge" do
      Collector.set_gauge("memory_bytes", %{region: "iad"}, 1024)

      output = Collector.prometheus_format()

      assert output =~ "# TYPE memory_bytes gauge"
      assert output =~ ~r/memory_bytes\{region="iad"\} 1024/
    end

    test "formats histogram with buckets" do
      Collector.observe_histogram("request_duration_seconds", %{}, 0.5)

      output = Collector.prometheus_format()

      assert output =~ "# TYPE request_duration_seconds histogram"
      assert output =~ ~r/request_duration_seconds_bucket\{le="0.001"\}/
      assert output =~ ~r/request_duration_seconds_bucket\{le="1.0"\}/
      assert output =~ ~r/request_duration_seconds_bucket\{le="\+Inf"\}/
      assert output =~ "request_duration_seconds_sum"
      assert output =~ "request_duration_seconds_count"
    end

    test "handles metrics without labels" do
      Collector.increment_counter("total_requests", %{}, 42)

      output = Collector.prometheus_format()

      assert output =~ "total_requests 42"
    end
  end

  describe "telemetry event handlers" do
    setup do
      Collector.attach_handlers()

      on_exit(fn ->
        Collector.detach_handlers()
      end)

      :ok
    end

    test "handles machine started event" do
      :telemetry.execute(
        [:orchestrator, :machine, :started],
        %{duration_ms: 123},
        %{region: "iad", machine_id: "m1"}
      )

      Process.sleep(100)

      metrics = Collector.get_metrics()

      counter = Enum.find(metrics, &(&1.name == "orchestrator_machine_starts_total"))
      assert counter != nil
      assert counter.value == 1

      histogram = Enum.find(metrics, &(&1.name == "orchestrator_machine_start_duration_seconds"))
      assert histogram != nil
      assert histogram.count == 1
    end

    test "handles machine stopped event" do
      :telemetry.execute(
        [:orchestrator, :machine, :stopped],
        %{},
        %{region: "iad"}
      )

      Process.sleep(100)

      metrics = Collector.get_metrics()

      counter = Enum.find(metrics, &(&1.name == "orchestrator_machine_stops_total"))
      assert counter != nil
      assert counter.value == 1
    end

    test "handles migration completed event" do
      :telemetry.execute(
        [:orchestrator, :migration, :completed],
        %{duration_ms: 5000},
        %{region: "iad"}
      )

      Process.sleep(100)

      metrics = Collector.get_metrics()

      counter =
        Enum.find(metrics, fn m ->
          m.name == "orchestrator_migrations_total" and
            m.labels[:status] == "success"
        end)

      assert counter != nil
      assert counter.value == 1

      histogram = Enum.find(metrics, &(&1.name == "orchestrator_migration_duration_seconds"))
      assert histogram != nil
    end

    test "handles migration failed event" do
      :telemetry.execute(
        [:orchestrator, :migration, :failed],
        %{},
        %{region: "iad"}
      )

      Process.sleep(100)

      metrics = Collector.get_metrics()

      counter =
        Enum.find(metrics, fn m ->
          m.name == "orchestrator_migrations_total" and
            m.labels[:status] == "failure"
        end)

      assert counter != nil
      assert counter.value == 1
    end

    test "handles FSM transition event" do
      :telemetry.execute(
        [:orchestrator, :fsm, :transition],
        %{duration_us: 500},
        %{from: "created", to: "starting"}
      )

      Process.sleep(100)

      metrics = Collector.get_metrics()

      counter = Enum.find(metrics, &(&1.name == "orchestrator_fsm_transitions_total"))
      assert counter != nil

      histogram = Enum.find(metrics, &(&1.name == "orchestrator_fsm_transition_duration_seconds"))
      assert histogram != nil
    end

    test "handles CRDT gossip event" do
      :telemetry.execute(
        [:orchestrator, :crdt, :gossip_sent],
        %{bytes: 1024},
        %{node: "node1"}
      )

      Process.sleep(100)

      metrics = Collector.get_metrics()

      counter = Enum.find(metrics, &(&1.name == "orchestrator_crdt_gossip_messages_total"))
      assert counter != nil
    end
  end

  describe "concurrent safety" do
    test "handles concurrent counter increments" do
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            Collector.increment_counter("test_counter", %{region: "iad"}, 1)
          end)
        end

      Task.await_many(tasks)

      metrics = Collector.get_metrics()
      counter = Enum.find(metrics, &(&1.name == "test_counter"))

      assert counter.value == 100
    end

    test "handles concurrent gauge updates" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Collector.set_gauge("test_gauge", %{region: "iad"}, i)
          end)
        end

      Task.await_many(tasks)

      metrics = Collector.get_metrics()
      gauge = Enum.find(metrics, &(&1.name == "test_gauge"))

      assert gauge.value in 1..50
    end

    test "handles concurrent histogram observations" do
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            Collector.observe_histogram("test_histogram", %{region: "iad"}, 0.5)
          end)
        end

      Task.await_many(tasks)

      metrics = Collector.get_metrics()
      histogram = Enum.find(metrics, &(&1.name == "test_histogram"))

      assert histogram.count == 100
      assert histogram.sum == 50.0
    end
  end

  describe "edge cases" do
    test "counter with zero value" do
      Collector.increment_counter("test_counter", %{}, 0)

      metrics = Collector.get_metrics()
      counter = Enum.find(metrics, &(&1.name == "test_counter"))

      assert counter.value == 0
    end

    test "gauge with negative value" do
      Collector.set_gauge("test_gauge", %{}, -42)

      metrics = Collector.get_metrics()
      gauge = Enum.find(metrics, &(&1.name == "test_gauge"))

      assert gauge.value == -42
    end

    test "histogram with zero observation" do
      Collector.observe_histogram("test_histogram", %{}, 0.0)

      metrics = Collector.get_metrics()
      histogram = Enum.find(metrics, &(&1.name == "test_histogram"))

      assert histogram.count == 1
      assert histogram.sum == 0.0
    end

    test "histogram with large value" do
      Collector.observe_histogram("test_histogram", %{}, 999.0)

      metrics = Collector.get_metrics()
      histogram = Enum.find(metrics, &(&1.name == "test_histogram"))

      infinity_bucket = Enum.find(histogram.buckets, fn {le, _count} -> le == :infinity end)
      assert infinity_bucket == {:infinity, 1}
    end

    test "metric with empty labels" do
      Collector.increment_counter("test_counter", %{}, 1)

      output = Collector.prometheus_format()

      assert output =~ "test_counter 1"
      refute output =~ "test_counter{}"
    end
  end

  describe "performance" do
    @tag :performance
    test "handles 10,000 counter increments efficiently" do
      start_time = System.monotonic_time(:microsecond)

      for i <- 1..10_000 do
        Collector.increment_counter("perf_counter", %{id: rem(i, 100)}, 1)
      end

      end_time = System.monotonic_time(:microsecond)
      duration_ms = div(end_time - start_time, 1000)

      assert duration_ms < 1000
    end

    @tag :performance
    test "prometheus_format scales with metric count" do
      for i <- 1..1000 do
        Collector.increment_counter("metric_#{i}", %{}, i)
      end

      start_time = System.monotonic_time(:microsecond)
      _output = Collector.prometheus_format()
      end_time = System.monotonic_time(:microsecond)

      duration_ms = div(end_time - start_time, 1000)

      assert duration_ms < 100
    end
  end
end
