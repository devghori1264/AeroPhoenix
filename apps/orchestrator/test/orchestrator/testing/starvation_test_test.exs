defmodule Orchestrator.Testing.StarvationTestTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Testing.StarvationTest

  setup do
    if pid = Process.whereis(StarvationTest) do
      Process.exit(pid, :kill)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      end
    end

    {:ok, pid} = StarvationTest.start_link()
    StarvationTest.reset(pid)

    {:ok, test_pid: pid}
  end

  describe "set_capacity/2" do
    test "sets region capacity limit" do
      :ok = StarvationTest.set_capacity("iad", 1000)

      stats = StarvationTest.get_capacity_stats("iad")

      assert stats.total == 1000
    end

    test "updates existing capacity" do
      StarvationTest.set_capacity("iad", 500)
      StarvationTest.set_capacity("iad", 1000)

      stats = StarvationTest.get_capacity_stats("iad")

      assert stats.total == 1000
    end
  end

  describe "fill_to_capacity/2" do
    test "fills region to target capacity" do
      StarvationTest.set_capacity("iad", 100)

      {:ok, machines} = StarvationTest.fill_to_capacity("iad", 100)

      assert length(machines) == 100

      stats = StarvationTest.get_capacity_stats("iad")
      assert stats.used == 100
      assert stats.available == 0
    end

    test "spawns machines concurrently" do
      StarvationTest.set_capacity("iad", 1000)

      start_time = System.monotonic_time(:millisecond)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 1000)
      end_time = System.monotonic_time(:millisecond)

      duration_ms = end_time - start_time

      assert duration_ms < 30_000
    end
  end

  describe "test_starvation/1" do
    test "returns insufficient_capacity when region full" do
      StarvationTest.set_capacity("iad", 100)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 100)

      result = StarvationTest.test_starvation("iad")

      assert result == {:error, :insufficient_capacity}
    end

    test "returns ok when region has capacity" do
      StarvationTest.set_capacity("iad", 100)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 50)

      result = StarvationTest.test_starvation("iad")

      assert {:ok, _machine_id} = result
    end

    test "detects exact capacity boundary" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      assert StarvationTest.test_starvation("iad") == {:error, :insufficient_capacity}

      StarvationTest.clear_region("iad")
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 9)

      assert {:ok, _machine_id} = StarvationTest.test_starvation("iad")
    end
  end

  describe "retry_with_backoff/2" do
    test "exhausts retries when region full" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      result =
        StarvationTest.retry_with_backoff(StarvationTest, "iad",
          max_retries: 3,
          base_delay_ms: 10
        )

      assert result == {:error, :max_retries_exceeded}
    end

    test "succeeds if capacity becomes available" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, machines} = StarvationTest.fill_to_capacity("iad", 10)

      Task.async(fn ->
        Process.sleep(50)
        StarvationTest.deallocate_machine(hd(machines))
      end)

      result =
        StarvationTest.retry_with_backoff(StarvationTest, "iad",
          max_retries: 10,
          base_delay_ms: 20
        )

      assert {:ok, _machine_id} = result
    end

    test "respects exponential backoff delays" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      start_time = System.monotonic_time(:millisecond)

      StarvationTest.retry_with_backoff(StarvationTest, "iad",
        max_retries: 3,
        base_delay_ms: 100,
        jitter: false
      )

      end_time = System.monotonic_time(:millisecond)

      duration_ms = end_time - start_time

      assert duration_ms >= 700
      assert duration_ms < 1000
    end

    test "jitter randomizes delay" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      durations =
        for _ <- 1..5 do
          start_time = System.monotonic_time(:millisecond)

          StarvationTest.retry_with_backoff(
            StarvationTest,
            "iad",
            max_retries: 2,
            base_delay_ms: 100,
            jitter: true
          )

          end_time = System.monotonic_time(:millisecond)
          end_time - start_time
        end

      unique_durations = Enum.uniq(durations) |> length()
      assert unique_durations > 1
    end
  end

  describe "find_available_region/1" do
    test "finds first available region" do
      StarvationTest.set_capacity("iad", 10)
      StarvationTest.set_capacity("ord", 10)
      StarvationTest.set_capacity("dfw", 10)

      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      result = StarvationTest.find_available_region(["iad", "ord", "dfw"])

      assert {:ok, {_machine_id, "ord"}} = result
    end

    test "returns no_available_regions when all full" do
      StarvationTest.set_capacity("iad", 10)
      StarvationTest.set_capacity("ord", 10)

      {:ok, _machines1} = StarvationTest.fill_to_capacity("iad", 10)
      {:ok, _machines2} = StarvationTest.fill_to_capacity("ord", 10)

      result = StarvationTest.find_available_region(["iad", "ord"])

      assert result == {:error, :no_available_regions}
    end

    test "tries regions in order" do
      StarvationTest.set_capacity("iad", 10)
      StarvationTest.set_capacity("ord", 10)
      StarvationTest.set_capacity("dfw", 10)

      {:ok, _machines1} = StarvationTest.fill_to_capacity("iad", 10)
      {:ok, _machines2} = StarvationTest.fill_to_capacity("ord", 10)

      result = StarvationTest.find_available_region(["iad", "ord", "dfw"])

      assert {:ok, {_machine_id, "dfw"}} = result
    end

    test "handles empty region list" do
      result = StarvationTest.find_available_region([])

      assert result == {:error, :no_available_regions}
    end
  end

  describe "get_capacity_stats/1" do
    test "returns accurate statistics" do
      StarvationTest.set_capacity("iad", 1000)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 850)

      stats = StarvationTest.get_capacity_stats("iad")

      assert stats.total == 1000
      assert stats.used == 850
      assert stats.available == 150
      assert stats.utilization == 0.85
      assert stats.status == :critical
    end

    test "status reflects utilization levels" do
      StarvationTest.set_capacity("test", 100)

      {:ok, _} = StarvationTest.fill_to_capacity("test", 50)
      stats = StarvationTest.get_capacity_stats("test")
      assert stats.status == :healthy

      StarvationTest.clear_region("test")
      {:ok, _} = StarvationTest.fill_to_capacity("test", 80)
      stats = StarvationTest.get_capacity_stats("test")
      assert stats.status == :warning

      StarvationTest.clear_region("test")
      {:ok, _} = StarvationTest.fill_to_capacity("test", 95)
      stats = StarvationTest.get_capacity_stats("test")
      assert stats.status == :critical

      StarvationTest.clear_region("test")
      {:ok, _} = StarvationTest.fill_to_capacity("test", 100)
      stats = StarvationTest.get_capacity_stats("test")
      assert stats.status == :full
    end

    test "handles region with no capacity set" do
      stats = StarvationTest.get_capacity_stats("unconfigured")

      assert stats.total == 0
      assert stats.used == 0
      assert stats.available == 0
    end
  end

  describe "deallocate_machine/1" do
    test "frees capacity" do
      StarvationTest.set_capacity("iad", 100)
      {:ok, machines} = StarvationTest.fill_to_capacity("iad", 100)

      stats_before = StarvationTest.get_capacity_stats("iad")
      assert stats_before.available == 0

      StarvationTest.deallocate_machine(hd(machines))

      stats_after = StarvationTest.get_capacity_stats("iad")
      assert stats_after.available == 1
    end

    test "allows new allocation after deallocation" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, machines} = StarvationTest.fill_to_capacity("iad", 10)

      assert StarvationTest.test_starvation("iad") == {:error, :insufficient_capacity}

      StarvationTest.deallocate_machine(hd(machines))

      assert {:ok, _machine_id} = StarvationTest.test_starvation("iad")
    end
  end

  describe "clear_region/1" do
    test "removes all machines from region" do
      StarvationTest.set_capacity("iad", 100)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 100)

      stats_before = StarvationTest.get_capacity_stats("iad")
      assert stats_before.used == 100

      StarvationTest.clear_region("iad")

      stats_after = StarvationTest.get_capacity_stats("iad")
      assert stats_after.used == 0
      assert stats_after.available == 100
    end

    test "doesn't affect other regions" do
      StarvationTest.set_capacity("iad", 50)
      StarvationTest.set_capacity("ord", 50)

      {:ok, _machines1} = StarvationTest.fill_to_capacity("iad", 50)
      {:ok, _machines2} = StarvationTest.fill_to_capacity("ord", 50)

      StarvationTest.clear_region("iad")

      iad_stats = StarvationTest.get_capacity_stats("iad")
      ord_stats = StarvationTest.get_capacity_stats("ord")

      assert iad_stats.used == 0
      assert ord_stats.used == 50
    end
  end

  describe "telemetry events" do
    setup do
      test_pid = self()

      :telemetry.attach_many(
        "starvation-test-handler",
        [
          [:orchestrator, :starvation_test, :region_filled],
          [:orchestrator, :starvation_test, :capacity_exceeded],
          [:orchestrator, :starvation_test, :retry_exhausted],
          [:orchestrator, :starvation_test, :fallback_success],
          [:orchestrator, :starvation_test, :all_regions_full]
        ],
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

      on_exit(fn ->
        :telemetry.detach("starvation-test-handler")
      end)

      :ok
    end

    test "emits region_filled event" do
      StarvationTest.set_capacity("iad", 100)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 100)

      assert_receive {:telemetry_event, [:orchestrator, :starvation_test, :region_filled],
                      measurements, metadata}

      assert measurements.count == 100
      assert metadata.region == "iad"
    end

    test "emits capacity_exceeded event" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      StarvationTest.test_starvation("iad")

      assert_receive {:telemetry_event, [:orchestrator, :starvation_test, :capacity_exceeded],
                      %{}, metadata}

      assert metadata.region == "iad"
    end

    test "emits retry_exhausted event" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      StarvationTest.retry_with_backoff(StarvationTest, "iad", max_retries: 3, base_delay_ms: 10)

      assert_receive {:telemetry_event, [:orchestrator, :starvation_test, :retry_exhausted],
                      measurements, metadata}

      assert measurements.attempts == 3
      assert metadata.region == "iad"
    end

    test "emits fallback_success event" do
      StarvationTest.set_capacity("iad", 10)
      StarvationTest.set_capacity("ord", 10)

      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      StarvationTest.find_available_region(["iad", "ord"])

      assert_receive {:telemetry_event, [:orchestrator, :starvation_test, :fallback_success], %{},
                      metadata}

      assert metadata.region == "ord"
    end

    test "emits all_regions_full event" do
      StarvationTest.set_capacity("iad", 10)
      StarvationTest.set_capacity("ord", 10)

      {:ok, _machines1} = StarvationTest.fill_to_capacity("iad", 10)
      {:ok, _machines2} = StarvationTest.fill_to_capacity("ord", 10)

      StarvationTest.find_available_region(["iad", "ord"])

      assert_receive {:telemetry_event, [:orchestrator, :starvation_test, :all_regions_full], %{},
                      %{}}
    end
  end

  describe "concurrent safety" do
    test "handles concurrent allocations" do
      StarvationTest.set_capacity("iad", 100)

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            StarvationTest.fill_to_capacity("iad", 1)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      assert Enum.all?(results, fn {:ok, machines} -> length(machines) == 1 end)

      stats = StarvationTest.get_capacity_stats("iad")
      assert stats.used == 100
    end

    test "concurrent deallocations don't corrupt state" do
      StarvationTest.set_capacity("iad", 100)
      {:ok, machines} = StarvationTest.fill_to_capacity("iad", 100)

      tasks =
        Enum.map(machines, fn machine_id ->
          Task.async(fn ->
            StarvationTest.deallocate_machine(machine_id)
          end)
        end)

      Task.await_many(tasks)

      stats = StarvationTest.get_capacity_stats("iad")
      assert stats.used == 0
    end
  end

  describe "edge cases" do
    test "capacity of 0 always returns insufficient" do
      StarvationTest.set_capacity("iad", 0)

      result = StarvationTest.test_starvation("iad")

      assert result == {:error, :insufficient_capacity}
    end

    test "filling to 0 machines" do
      StarvationTest.set_capacity("iad", 100)

      {:ok, machines} = StarvationTest.fill_to_capacity("iad", 0)

      assert machines == []
    end

    test "retry with 0 max_retries" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      result = StarvationTest.retry_with_backoff(StarvationTest, "iad", max_retries: 0)

      assert result == {:error, :max_retries_exceeded}
    end

    test "retry with 0 base_delay" do
      StarvationTest.set_capacity("iad", 10)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 10)

      start_time = System.monotonic_time(:millisecond)
      StarvationTest.retry_with_backoff(StarvationTest, "iad", max_retries: 3, base_delay_ms: 0)
      end_time = System.monotonic_time(:millisecond)

      duration_ms = end_time - start_time

      assert duration_ms < 100
    end
  end

  describe "performance benchmarks" do
    @tag :performance
    test "fills 1000 machines efficiently" do
      StarvationTest.set_capacity("iad", 1000)

      start_time = System.monotonic_time(:millisecond)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 1000)
      end_time = System.monotonic_time(:millisecond)

      duration_ms = end_time - start_time

      assert duration_ms < 10_000
    end

    @tag :performance
    test "capacity check is fast" do
      StarvationTest.set_capacity("iad", 10000)
      {:ok, _machines} = StarvationTest.fill_to_capacity("iad", 5000)

      start_time = System.monotonic_time(:microsecond)
      _stats = StarvationTest.get_capacity_stats("iad")
      end_time = System.monotonic_time(:microsecond)

      duration_us = end_time - start_time

      assert duration_us < 5000,
             "Capacity check took #{duration_us}μs, expected < 5000μs"
    end
  end

  def handle_telemetry_event(event_name, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event_name, measurements, metadata})
  end
end
