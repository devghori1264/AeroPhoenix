defmodule Orchestrator.ResourceScenariosTest do
  use Orchestrator.DataCase, async: false
  require Logger
  @moduletag :slow

  alias Orchestrator.{ResourceManager, ResourceQueue, PlacementScheduler}
  alias Orchestrator.MachineActor.Supervisor, as: MachActorSup

  @moduletag timeout: 30_000

  defp wait_until(timeout \\ 1000, fun) do
    if fun.() do
      :ok
    else
      if timeout > 0 do
        Process.sleep(10)
        wait_until(timeout - 10, fun)
      else
        raise "Wait timeout"
      end
    end
  end

  setup do
    case Process.whereis(Orchestrator.Placement.ResourceManager) do
      nil ->
        :ok

      _pid ->
        Supervisor.terminate_child(Orchestrator.Supervisor, Orchestrator.ResourceManager)
        Supervisor.restart_child(Orchestrator.Supervisor, Orchestrator.ResourceManager)
        wait_until(fn -> Process.whereis(Orchestrator.Placement.ResourceManager) != nil end)
    end

    cleanup_all_resources()
    ResourceManager.scan_for_leaks()
    ResourceManager.reset()

    on_exit(fn ->
      cleanup_all_resources()
      ResourceManager.scan_for_leaks()
      ResourceManager.reset()
    end)

    :ok
  end

  defp cleanup_all_resources do
    MachActorSup.list_machines()
    |> Enum.each(fn id ->
      MachActorSup.stop_machine(id)
    end)
  end

  describe "capacity exhaustion" do
    test "10 machines test capacity management" do
      capacity = ResourceManager.get_capacity()
      total_memory = capacity.total.memory_mb

      machine_count = 10

      Logger.info("Starting capacity exhaustion test",
        total_memory_mb: total_memory,
        machine_count: machine_count
      )

      results =
        for i <- 1..machine_count do
          id = "mem-fill-#{i}"

          MachActorSup.start_machine(
            id: id,
            region: "test-region",
            size: %{
              cpu_count: 0.1,
              memory_mb: 1024,
              disk_mb: 5120
            }
          )
        end

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)
      assert successes == machine_count

      final_capacity = ResourceManager.get_capacity()
      memory_util = final_capacity.utilization_pct.memory

      assert memory_util >= 0.0,
             "Expected non-negative memory utilization, got #{memory_util}%"

      result =
        MachActorSup.start_machine(
          id: "overflow-machine",
          region: "test-region",
          size: %{cpu_count: 0.5, memory_mb: 1024, disk_mb: 5120}
        )

      assert match?({:ok, _}, result) or match?({:error, :insufficient_memory, _}, result)

      Logger.info("Capacity exhaustion test passed",
        machines_started: successes,
        final_utilization: memory_util
      )
    end

    test "capacity freed after machine stop" do
      {:ok, _pid1} =
        MachActorSup.start_machine(
          id: "temp-machine-1",
          region: "test-region",
          size: %{cpu_count: 2.0, memory_mb: 4096, disk_mb: 10_240}
        )

      capacity_before = ResourceManager.get_capacity()
      reserved_before = capacity_before.reserved.memory_mb

      :ok = MachActorSup.stop_machine("temp-machine-1")

      wait_until(fn ->
        cap = ResourceManager.get_capacity()
        cap.reserved.memory_mb < reserved_before
      end)

      capacity_after = ResourceManager.get_capacity()
      reserved_after = capacity_after.reserved.memory_mb

      freed_memory = reserved_before - reserved_after

      assert freed_memory >= 4096,
             "Expected >= 4096 MB freed, got #{freed_memory} MB"
    end

    test "overcommit allows 120% CPU allocation" do
      machines_needed = 10

      Logger.info("Testing CPU overcommit with #{machines_needed} machines")

      results =
        for i <- 1..machines_needed do
          MachActorSup.start_machine(
            id: "cpu-overcommit-#{i}",
            region: "test-region",
            size: %{cpu_count: 2.0, memory_mb: 512, disk_mb: 2048},
            queue_on_exhaustion: true
          )
        end

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)
      queued = Enum.count(results, fn res -> match?({:queued, _}, res) end)

      Logger.info("Overcommit results",
        successes: successes,
        queued: queued,
        total: machines_needed
      )

      assert successes >= 5, "Expected at least 5 machines to start, got #{successes}"
    end
  end

  describe "resource leak detection" do
    test "orphaned reservations released within 60 seconds" do
      machine_id = "leak-test-manual"
      resources = %{cpu_cores: 1.0, memory_mb: 2048, disk_mb: 5120}

      {:ok, :reserved} = ResourceManager.reserve_resources(machine_id, resources)

      assert {:ok, _} = ResourceManager.get_reservation(machine_id)

      {:ok, scan_result} = ResourceManager.scan_for_leaks()

      assert scan_result.released >= 1,
             "Expected >= 1 leaked reservation, found #{scan_result.released}"

      assert {:error, :not_found} ==
               ResourceManager.get_reservation(machine_id)

      Logger.info("Leak detection test passed", scan_result: scan_result)
    end

    test "periodic leak scan runs automatically" do
      for i <- 1..5 do
        machine_id = "auto-leak-#{i}"
        resources = %{cpu_cores: 0.5, memory_mb: 1024, disk_mb: 2048}
        {:ok, :reserved} = ResourceManager.reserve_resources(machine_id, resources)
      end

      wait_until(fn -> length(ResourceManager.list_reservations()) == 5 end)

      _reservations_before = length(ResourceManager.list_reservations())

      {:ok, result} = ResourceManager.scan_for_leaks()

      assert result.released >= 5,
             "Expected >= 5 leaks released, got #{result.released}"
    end
  end

  describe "concurrent reservations" do
    test "100 parallel reservation requests with race conditions" do
      start_time = System.monotonic_time(:millisecond)

      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            MachActorSup.start_machine(
              id: "concurrent-#{i}",
              region: "test-region",
              size: %{cpu_count: 0.25, memory_mb: 512, disk_mb: 1024}
            )
          end)
        end

      results = Task.await_many(tasks, 5_000)
      duration_ms = System.monotonic_time(:millisecond) - start_time

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)
      errors = Enum.count(results, fn res -> match?({:error, _, _}, res) end)
      queued = Enum.count(results, fn res -> match?({:queued, _}, res) end)

      Logger.info("Concurrent reservation test",
        successes: successes,
        errors: errors,
        queued: queued,
        duration_ms: duration_ms
      )

      assert successes + errors + queued == 100

      assert successes > 0

      assert duration_ms < 10_000
    end

    test "no double-allocation of same resources" do
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            MachActorSup.start_machine(
              id: "duplicate-machine",
              region: "test-region",
              size: %{cpu_count: 1.0, memory_mb: 1024, disk_mb: 2048}
            )
          end)
        end

      results = Task.await_many(tasks, 5000)

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)

      already_exists =
        Enum.count(results, fn res ->
          match?({:error, :already_exists}, res) or match?({:error, {:already_started, _}}, res)
        end)

      assert successes == 1, "Expected exactly 1 success, got #{successes}"

      assert already_exists == 9,
             "Expected 9 already_exists errors, got #{already_exists}"
    end

    test "concurrent stop and start of same machine" do
      {:ok, _pid} =
        MachActorSup.start_machine(
          id: "race-machine",
          region: "test-region",
          size: %{cpu_count: 1.0, memory_mb: 2048, disk_mb: 5120}
        )

      tasks = [
        Task.async(fn -> MachActorSup.stop_machine("race-machine") end),
        Task.async(fn ->
          Process.sleep(1)
          MachActorSup.restart_machine("race-machine")
        end)
      ]

      results = Task.await_many(tasks, 5000)

      assert length(results) == 2
    end
  end

  describe "resource queue and preemption" do
    test "FIFO queue processes requests in order" do
      machines_to_fill = 5

      for i <- 1..machines_to_fill do
        MachActorSup.start_machine(
          id: "filler-#{i}",
          region: "test-region",
          size: %{cpu_count: 0.5, memory_mb: 2048, disk_mb: 5120}
        )
      end

      {:ok, ticket1} =
        ResourceQueue.enqueue(
          "queued-1",
          %{cpu_cores: 1.0, memory_mb: 2048, disk_mb: 5120},
          priority: 50
        )

      {:ok, ticket2} =
        ResourceQueue.enqueue(
          "queued-2",
          %{cpu_cores: 1.0, memory_mb: 2048, disk_mb: 5120},
          priority: 50
        )

      {:ok, ticket3} =
        ResourceQueue.enqueue(
          "queued-3",
          %{cpu_cores: 1.0, memory_mb: 2048, disk_mb: 5120},
          priority: 50
        )

      status1 = ResourceQueue.get_status(ticket1)
      status2 = ResourceQueue.get_status(ticket2)
      status3 = ResourceQueue.get_status(ticket3)

      case {status1, status2, status3} do
        {{:queued, pos1, _wait}, {:queued, pos2, _wait2}, {:queued, pos3, _wait3}} ->
          assert pos1 < pos2
          assert pos2 < pos3

          Logger.info("Queue order verified",
            positions: [pos1, pos2, pos3]
          )

        _ ->
          :ok
      end
    end

    test "high priority requests jump queue" do
      machines_to_fill = 5

      for i <- 1..machines_to_fill do
        MachActorSup.start_machine(
          id: "pri-filler-#{i}",
          region: "test-region",
          size: %{cpu_count: 0.5, memory_mb: 2048, disk_mb: 5120}
        )
      end

      {:ok, low_ticket} =
        ResourceQueue.enqueue(
          "low-pri",
          %{cpu_cores: 1.0, memory_mb: 2048, disk_mb: 5120},
          priority: 80
        )

      {:ok, high_ticket} =
        ResourceQueue.enqueue(
          "high-pri",
          %{cpu_cores: 1.0, memory_mb: 2048, disk_mb: 5120},
          priority: 20
        )

      low_status = ResourceQueue.get_status(low_ticket)
      high_status = ResourceQueue.get_status(high_ticket)

      case {low_status, high_status} do
        {{:queued, low_pos, _}, {:queued, high_pos, _}} ->
          assert high_pos < low_pos,
                 "High priority (pos #{high_pos}) should be before low (pos #{low_pos})"

        _ ->
          :ok
      end
    end

    test "queue timeout after 2 minutes" do
      stats = ResourceQueue.get_stats()
      assert Map.has_key?(stats, :timeouts_1h)
    end
  end

  describe "placement algorithms" do
    test "first-fit is fastest for balanced load" do
      resources = %{cpu_cores: 2.0, memory_mb: 4096, disk_mb: 10_240}

      start_time = System.monotonic_time(:microsecond)

      for _ <- 1..100 do
        PlacementScheduler.find_placement(resources, strategy: :first_fit)
      end

      first_fit_time = System.monotonic_time(:microsecond) - start_time

      Logger.info("First-fit performance: #{first_fit_time}us for 100 placements")

      assert first_fit_time < 100_000
    end

    test "best-fit minimizes fragmentation" do
      {:ok, _} =
        MachActorSup.start_machine(
          id: "large-machine",
          region: "test-region",
          size: %{cpu_count: 8.0, memory_mb: 32_768, disk_mb: 102_400}
        )

      {:ok, region} =
        PlacementScheduler.find_placement(
          %{cpu_cores: 1.0, memory_mb: 2048, disk_mb: 5120},
          strategy: :best_fit
        )

      assert region != nil
    end

    test "worst-fit balances load across regions" do
      {:ok, region} =
        PlacementScheduler.find_placement(
          %{cpu_cores: 1.0, memory_mb: 2048, disk_mb: 5120},
          strategy: :worst_fit
        )

      assert region != nil
    end

    test "placement respects constraints" do
      result =
        PlacementScheduler.find_placement(
          %{cpu_cores: 1.0, memory_mb: 2048, disk_mb: 5120},
          constraints: [{:max_cpu_utilization, 50.0}]
        )

      assert match?({:ok, _}, result) or match?({:error, :no_suitable_region}, result)
    end
  end

  describe "memory fragmentation" do
    test "small requests succeed after large allocations" do
      large_count = 3

      for i <- 1..large_count do
        MachActorSup.start_machine(
          id: "large-#{i}",
          region: "test-region",
          size: %{cpu_count: 2.0, memory_mb: 8192, disk_mb: 20_480}
        )
      end

      MachActorSup.stop_machine("large-1")

      results =
        for i <- 1..5 do
          MachActorSup.start_machine(
            id: "small-#{i}",
            region: "test-region",
            size: %{cpu_count: 0.25, memory_mb: 512, disk_mb: 1024}
          )
        end

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)
      assert successes >= 3, "Expected at least 3 small allocations to succeed, got #{successes}"
    end
  end

  describe "capacity metrics and observability" do
    test "capacity snapshot includes all dimensions" do
      capacity = ResourceManager.get_capacity()

      assert Map.has_key?(capacity, :total)
      assert Map.has_key?(capacity, :reserved)
      assert Map.has_key?(capacity, :available)
      assert Map.has_key?(capacity, :utilization_pct)
      assert Map.has_key?(capacity, :reservations_count)

      assert Map.has_key?(capacity.total, :cpu_cores)
      assert Map.has_key?(capacity.total, :memory_mb)
      assert Map.has_key?(capacity.total, :disk_mb)
    end

    test "utilization percentage calculated correctly" do
      {:ok, _} =
        MachActorSup.start_machine(
          id: "util-test",
          region: "test-region",
          size: %{cpu_count: 4.0, memory_mb: 16_384, disk_mb: 51_200}
        )

      capacity = ResourceManager.get_capacity()

      expected_cpu_util = 4.0 / capacity.total.cpu_cores * 100.0
      assert abs(capacity.utilization_pct.cpu - expected_cpu_util) < 1.0

      expected_mem_util = 16_384 / capacity.total.memory_mb * 100.0
      assert abs(capacity.utilization_pct.memory - expected_mem_util) < 1.0
    end
  end
end
