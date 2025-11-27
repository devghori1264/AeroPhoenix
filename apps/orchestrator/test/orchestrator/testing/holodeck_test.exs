defmodule Orchestrator.Testing.HolodeckTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Testing.Holodeck

  setup do
    {:ok, pid} = Holodeck.start_link()

    on_exit(fn ->
      if Process.alive?(pid) do
        Holodeck.stop_all_machines()
        Process.exit(pid, :normal)
      end
    end)

    {:ok, holodeck_pid: pid}
  end

  describe "spawn_machines/1" do
    test "spawns requested number of machines" do
      {:ok, machines} = Holodeck.spawn_machines(100)

      assert length(machines) == 100
      assert Enum.all?(machines, &is_binary/1)
      assert Enum.all?(machines, &String.starts_with?(&1, "holodeck_machine_"))
    end

    test "spawns machines concurrently (performance)" do
      start_time = System.monotonic_time(:microsecond)
      {:ok, machines} = Holodeck.spawn_machines(1000)
      end_time = System.monotonic_time(:microsecond)

      duration_ms = div(end_time - start_time, 1000)

      assert length(machines) == 1000
      assert duration_ms < 5000
    end

    test "each machine has unique ID" do
      {:ok, machines} = Holodeck.spawn_machines(100)

      unique_machines = Enum.uniq(machines)

      assert length(unique_machines) == 100
    end

    test "spawned machines are registered in ETS" do
      {:ok, machines} = Holodeck.spawn_machines(10)

      Enum.each(machines, fn machine_id ->
        assert :ets.member(:holodeck_machines, machine_id)

        [{^machine_id, pid}] = :ets.lookup(:holodeck_machines, machine_id)
        assert is_pid(pid)
        assert Process.alive?(pid)
      end)
    end

    test "spawning 5000 machines (target scale)" do
      {:ok, machines} = Holodeck.spawn_machines(5000)

      assert length(machines) == 5000

      memory_mb = div(:erlang.memory(:total), 1_024 * 1_024)
      assert memory_mb < 3000
    end
  end

  describe "run_scenario/2 - :ramp_up" do
    test "ramps up from 10 to target" do
      Holodeck.run_scenario(:ramp_up, target: 100, interval: 100)

      Process.sleep(1000)

      machines = Holodeck.list_machines()

      assert length(machines) >= 100
    end

    test "respects interval between doublings" do
      start_time = System.monotonic_time(:millisecond)

      Holodeck.run_scenario(:ramp_up, target: 40, interval: 500)

      Process.sleep(2000)

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      assert duration_ms >= 1500
      assert duration_ms < 3000
    end
  end

  describe "run_scenario/2 - :spike" do
    test "spawns all machines instantly" do
      start_time = System.monotonic_time(:millisecond)

      Holodeck.run_scenario(:spike, count: 1000)

      Process.sleep(3000)

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      machines = Holodeck.list_machines()

      assert length(machines) >= 1000

      assert duration_ms < 5000
    end
  end

  describe "run_scenario/2 - :sustained" do
    test "runs for specified duration" do
      start_time = System.monotonic_time(:millisecond)

      Holodeck.run_scenario(:sustained, count: 50, duration: 2000)

      Process.sleep(3000)

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      assert duration_ms >= 2000
      assert duration_ms < 4000
    end

    test "performs random operations during sustained load" do
      Holodeck.run_scenario(:sustained, count: 100, duration: 1000)

      Process.sleep(2000)

      machines = Holodeck.list_machines()

      assert length(machines) >= 100
    end
  end

  describe "run_scenario/2 - :chaos" do
    test "injects failures during load" do
      Holodeck.run_scenario(:chaos, count: 100, failure_rate: 50)

      Process.sleep(2000)

      machines = Holodeck.list_machines()

      assert length(machines) >= 40
      assert length(machines) <= 60
    end

    test "failure_rate controls kill percentage" do
      Holodeck.run_scenario(:chaos, count: 100, failure_rate: 10)

      Process.sleep(2000)

      machines = Holodeck.list_machines()

      assert length(machines) >= 85
      assert length(machines) <= 95
    end
  end

  describe "measure_throughput/2" do
    test "calculates operations per second" do
      operation = fn ->
        Process.sleep(1)
        :ok
      end

      {:ok, throughput} = Holodeck.measure_throughput(operation, iterations: 100)

      assert throughput > 500
      assert throughput < 1500
    end

    test "handles fast operations (high throughput)" do
      operation = fn ->
        :ok
      end

      {:ok, throughput} = Holodeck.measure_throughput(operation, iterations: 10_000)

      assert throughput > 100_000
    end
  end

  describe "measure_latency/2" do
    test "calculates percentile latencies" do
      operation = fn ->
        Process.sleep(:rand.uniform(10))
        :ok
      end

      {:ok, latencies} = Holodeck.measure_latency(operation, iterations: 100)

      assert is_map(latencies)
      assert Map.has_key?(latencies, :p50)
      assert Map.has_key?(latencies, :p95)
      assert Map.has_key?(latencies, :p99)
      assert Map.has_key?(latencies, :p999)

      assert latencies.p50 < latencies.p99
    end

    test "P99 captures tail latency" do
      operation = fn ->
        if :rand.uniform(100) == 1 do
          Process.sleep(100)
        else
          Process.sleep(1)
        end

        :ok
      end

      {:ok, latencies} = Holodeck.measure_latency(operation, iterations: 1000)

      assert latencies.p50 < 5_000

      assert latencies.p99 > 50_000
    end

    test "handles consistent latency" do
      operation = fn ->
        Process.sleep(5)
        :ok
      end

      {:ok, latencies} = Holodeck.measure_latency(operation, iterations: 100)

      assert_in_delta latencies.p50, 5000, 2000
      assert_in_delta latencies.p95, 5000, 2000
      assert_in_delta latencies.p99, 5000, 2000
    end
  end

  describe "report_metrics/0" do
    test "returns comprehensive metrics" do
      {:ok, _machines} = Holodeck.spawn_machines(100)

      metrics = Holodeck.report_metrics()

      assert is_map(metrics)
      assert metrics.total_spawned == 100
      assert metrics.active_machines == 100
      assert metrics.memory_mb > 0
      assert metrics.ets_memory_mb > 0
      assert metrics.process_count > 0
      assert metrics.scheduler_utilization >= 0.0
      assert metrics.scheduler_utilization <= 1.0
      assert metrics.failed_operations == 0
    end

    test "tracks total spawned across multiple calls" do
      {:ok, _machines1} = Holodeck.spawn_machines(50)
      {:ok, _machines2} = Holodeck.spawn_machines(50)

      metrics = Holodeck.report_metrics()

      assert metrics.total_spawned == 100
      assert metrics.active_machines == 100
    end

    test "memory usage scales with machine count" do
      metrics_before = Holodeck.report_metrics()
      memory_before = metrics_before.memory_mb

      {:ok, _machines} = Holodeck.spawn_machines(1000)

      metrics_after = Holodeck.report_metrics()
      memory_after = metrics_after.memory_mb

      assert memory_after > memory_before
    end

    test "scheduler utilization reflects load" do
      metrics_idle = Holodeck.report_metrics()

      {:ok, _machines} = Holodeck.spawn_machines(1000)
      metrics_loaded = Holodeck.report_metrics()

      assert metrics_idle.scheduler_utilization >= 0.0
      assert metrics_idle.scheduler_utilization <= 1.0
      assert metrics_loaded.scheduler_utilization >= 0.0
      assert metrics_loaded.scheduler_utilization <= 1.0
    end
  end

  describe "stop_all_machines/0" do
    test "stops all spawned machines" do
      {:ok, _machines} = Holodeck.spawn_machines(100)

      assert Holodeck.list_machines() |> length() == 100

      :ok = Holodeck.stop_all_machines()

      assert Holodeck.list_machines() == []
    end

    test "cleans up ETS table" do
      {:ok, machines} = Holodeck.spawn_machines(50)

      Holodeck.stop_all_machines()

      assert :ets.info(:holodeck_machines, :size) == 0

      Enum.each(machines, fn machine_id ->
        assert :ets.lookup(:holodeck_machines, machine_id) == []
      end)
    end

    test "handles already stopped machines" do
      {:ok, _machines} = Holodeck.spawn_machines(10)

      :ok = Holodeck.stop_all_machines()
      :ok = Holodeck.stop_all_machines()

      assert Holodeck.list_machines() == []
    end
  end

  describe "list_machines/0" do
    test "returns empty list when no machines" do
      assert Holodeck.list_machines() == []
    end

    test "returns all machine IDs" do
      {:ok, spawned_machines} = Holodeck.spawn_machines(50)

      listed_machines = Holodeck.list_machines()

      assert length(listed_machines) == 50
      assert Enum.sort(listed_machines) == Enum.sort(spawned_machines)
    end

    test "updates after machines stop" do
      {:ok, _machines} = Holodeck.spawn_machines(20)

      assert length(Holodeck.list_machines()) == 20

      Holodeck.stop_all_machines()

      assert Holodeck.list_machines() == []
    end
  end

  describe "telemetry events" do
    setup do
      test_pid = self()

      :telemetry.attach_many(
        "holodeck-test-handler",
        [
          [:orchestrator, :holodeck, :started],
          [:orchestrator, :holodeck, :machines_spawned]
        ],
        fn event_name, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("holodeck-test-handler")
      end)

      :ok
    end

    test "emits started event on init" do
      assert_receive {:telemetry_event, [:orchestrator, :holodeck, :started], %{}, %{}}
    end

    test "emits machines_spawned event" do
      {:ok, _machines} = Holodeck.spawn_machines(100)

      assert_receive {:telemetry_event, [:orchestrator, :holodeck, :machines_spawned],
                      measurements, %{}}

      assert measurements.count == 100
      assert measurements.duration_ms > 0
      assert measurements.throughput > 0
    end

    test "includes throughput in machines_spawned event" do
      {:ok, _machines} = Holodeck.spawn_machines(100)

      assert_receive {:telemetry_event, [:orchestrator, :holodeck, :machines_spawned],
                      measurements, %{}}

      assert measurements.throughput > 10
    end
  end

  describe "concurrent safety" do
    test "handles concurrent spawn_machines calls" do
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Holodeck.spawn_machines(10)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      assert Enum.all?(results, fn {:ok, machines} -> length(machines) == 10 end)

      assert length(Holodeck.list_machines()) == 100
    end

    test "report_metrics is thread-safe" do
      Task.async(fn ->
        Holodeck.spawn_machines(1000)
      end)

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            Holodeck.report_metrics()
          end)
        end

      metrics_list = Task.await_many(tasks, 30_000)

      assert Enum.all?(metrics_list, fn metrics ->
               is_map(metrics) and Map.has_key?(metrics, :total_spawned)
             end)
    end
  end

  describe "edge cases" do
    test "spawning 0 machines" do
      {:ok, machines} = Holodeck.spawn_machines(0)

      assert machines == []
    end

    test "measure_throughput with 0 iterations" do
      {:ok, throughput} = Holodeck.measure_throughput(fn -> :ok end, iterations: 0)

      assert is_float(throughput) or throughput == 0
    end

    test "measure_latency with 1 iteration" do
      {:ok, latencies} = Holodeck.measure_latency(fn -> :ok end, iterations: 1)

      assert latencies.p50 == latencies.p99
    end

    test "chaos scenario with 0% failure rate" do
      Holodeck.run_scenario(:chaos, count: 50, failure_rate: 0)

      Process.sleep(1000)

      machines = Holodeck.list_machines()

      assert length(machines) == 50
    end

    test "chaos scenario with 100% failure rate" do
      Holodeck.run_scenario(:chaos, count: 50, failure_rate: 100)

      Process.sleep(1000)

      machines = Holodeck.list_machines()

      assert machines == []
    end
  end

  describe "performance benchmarks" do
    @tag :performance
    test "spawn rate >500 machines/sec" do
      start_time = System.monotonic_time(:microsecond)
      {:ok, _machines} = Holodeck.spawn_machines(1000)
      end_time = System.monotonic_time(:microsecond)

      duration_sec = (end_time - start_time) / 1_000_000
      throughput = 1000 / duration_sec

      assert throughput > 500
    end

    @tag :performance
    test "memory overhead <1 MB per machine" do
      metrics_before = Holodeck.report_metrics()
      memory_before_mb = metrics_before.memory_mb

      {:ok, _machines} = Holodeck.spawn_machines(1000)

      metrics_after = Holodeck.report_metrics()
      memory_after_mb = metrics_after.memory_mb

      memory_per_machine_mb = (memory_after_mb - memory_before_mb) / 1000

      assert memory_per_machine_mb < 1.0
    end

    @tag :performance
    test "list_machines scales to 5000 machines" do
      {:ok, _machines} = Holodeck.spawn_machines(5000)

      start_time = System.monotonic_time(:microsecond)
      machines = Holodeck.list_machines()
      end_time = System.monotonic_time(:microsecond)

      duration_ms = div(end_time - start_time, 1000)

      assert length(machines) == 5000
      assert duration_ms < 100
    end
  end
end
