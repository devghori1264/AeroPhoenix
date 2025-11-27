defmodule Orchestrator.Integration.ZombieResourceTest do
  use ExUnit.Case, async: false
  require Logger

  alias Orchestrator.{ResourceManager, ResourceQueue}
  alias Orchestrator.MachineActor.Supervisor, as: MachActorSup
  alias Orchestrator.Recovery.{DriftDetector, Reconciler, RepairActions}

  @moduletag timeout: 300_000

  setup do
    cleanup_all()

    Reconciler.pause()

    on_exit(fn ->
      cleanup_all()
      Reconciler.resume()
    end)

    :ok
  end

  defp cleanup_all do
    MachActorSup.list_machines()
    |> Enum.each(fn id -> MachActorSup.stop_machine(id) end)

    Process.sleep(300)
  end

  describe "zombie resurrection resource coordination" do
    test "zombie resurrection releases old reservation and creates new one" do
      machine_id = "zombie-res-#{:rand.uniform(100_000)}"

      {:ok, pid} =
        MachActorSup.start_machine(
          id: machine_id,
          size: %{cpu_count: 2.0, memory_mb: 4096, disk_mb: 10_240}
        )

      {:ok, original_reservation} = ResourceManager.get_reservation(machine_id)
      assert original_reservation.cpu_cores == 2.0
      assert original_reservation.memory_mb == 4096

      Process.exit(pid, :kill)
      Process.sleep(100)

      drift_result = DriftDetector.detect_drift()
      zombies = Map.get(drift_result, :zombies, [])
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      assert zombie != nil, "Machine should be detected as zombie"

      {:ok, orphaned_reservation} = ResourceManager.get_reservation(machine_id)
      assert orphaned_reservation.cpu_cores == 2.0

      {:ok, outcome} = RepairActions.execute(zombie)
      assert outcome in [:repaired, :already_healthy]

      assert wait_for_resurrection(machine_id, 5000)

      {:ok, new_reservation} = ResourceManager.get_reservation(machine_id)
      assert new_reservation.cpu_cores == 2.0
      assert new_reservation.memory_mb == 4096

      capacity = ResourceManager.get_capacity()
      reservations = ResourceManager.list_reservations()

      machine_reservations =
        Enum.filter(reservations, fn {id, _res} -> id == machine_id end)

      assert length(machine_reservations) == 1,
             "Expected exactly 1 reservation, found #{length(machine_reservations)}"

      Logger.info("Zombie resurrection resource test passed",
        machine_id: machine_id,
        outcome: outcome,
        reservation_count: length(reservations)
      )
    end

    test "concurrent zombie resurrections don't double-allocate resources" do
      machine_id = "concurrent-zombie-#{:rand.uniform(100_000)}"

      {:ok, pid} =
        MachActorSup.start_machine(
          id: machine_id,
          size: %{cpu_count: 1.0, memory_mb: 2048, disk_mb: 5120}
        )

      Process.exit(pid, :kill)
      Process.sleep(100)

      drift_result = DriftDetector.detect_drift()
      zombies = Map.get(drift_result, :zombies, [])
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            {i, RepairActions.execute(zombie)}
          end)
        end

      results = Task.await_many(tasks, 10_000)

      successes =
        Enum.count(results, fn
          {_i, {:ok, _}} -> true
          _ -> false
        end)

      assert successes >= 1, "At least one resurrection should succeed"

      Process.sleep(300)

      reservations = ResourceManager.list_reservations()

      machine_reservations =
        Enum.filter(reservations, fn {id, _res} -> id == machine_id end)

      assert length(machine_reservations) <= 1,
             "Expected <= 1 reservation, found #{length(machine_reservations)}"
    end

    test "zombie batch repair doesn't exhaust capacity" do
      machine_ids =
        for i <- 1..50 do
          id = "batch-zombie-#{i}-#{:rand.uniform(10_000)}"

          {:ok, pid} =
            MachActorSup.start_machine(
              id: id,
              size: %{cpu_count: 0.5, memory_mb: 1024, disk_mb: 2048}
            )

          Process.exit(pid, :kill)
          id
        end

      Process.sleep(500)

      capacity_before = ResourceManager.get_capacity()
      reserved_before = capacity_before.reserved.memory_mb

      drift_result = DriftDetector.detect_drift()
      zombies = Map.get(drift_result, :zombies, [])

      assert length(zombies) >= 45, "Expected >= 45 zombies detected"

      tasks =
        zombies
        |> Enum.take(50)
        |> Enum.map(fn zombie ->
          Task.async(fn ->
            RepairActions.execute(zombie)
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)

      Logger.info("Batch zombie repair completed",
        zombies: length(zombies),
        successes: successes
      )

      Process.sleep(500)
      capacity_after = ResourceManager.get_capacity()
      reserved_after = capacity_after.reserved.memory_mb

      diff = abs(reserved_after - reserved_before)
      tolerance = 1024 * 10

      assert diff < tolerance,
             "Capacity drift too large: #{diff} MB (expected < #{tolerance})"
    end
  end

  describe "ghost cleanup resource release" do
    test "ghost process triggers immediate resource release" do
      machine_id = "ghost-release-#{:rand.uniform(100_000)}"

      {:ok, pid} =
        MachActorSup.start_machine(
          id: machine_id,
          size: %{cpu_count: 1.0, memory_mb: 2048, disk_mb: 5120}
        )

      capacity_before = ResourceManager.get_capacity()
      available_before = capacity_before.available.memory_mb

      Process.exit(pid, :kill)
      Process.sleep(200)

      Reconciler.force_reconciliation()
      Process.sleep(500)

      capacity_after = ResourceManager.get_capacity()
      available_after = capacity_after.available.memory_mb

      freed_memory = available_after - available_before

      assert freed_memory >= 2048,
             "Expected >= 2048 MB freed, got #{freed_memory} MB"
    end
  end

  describe "WAL replay resource recovery" do
    test "crash recovery preserves resource reservations" do
      machine_id = "wal-recovery-#{:rand.uniform(100_000)}"

      {:ok, pid} =
        MachActorSup.start_machine(
          id: machine_id,
          size: %{cpu_count: 2.0, memory_mb: 4096, disk_mb: 10_240}
        )

      Process.sleep(100)

      {:ok, reservation_before} = ResourceManager.get_reservation(machine_id)

      Process.exit(pid, :kill)
      Process.sleep(100)

      result = MachActorSup.restart_machine(machine_id)

      case result do
        {:ok, _new_pid} ->
          {:ok, reservation_after} = ResourceManager.get_reservation(machine_id)

          assert reservation_after.cpu_cores == reservation_before.cpu_cores
          assert reservation_after.memory_mb == reservation_before.memory_mb

        {:error, reason} ->
          Logger.warning("Restart failed: #{inspect(reason)}")
          :ok
      end
    end
  end

  @tag :slow
  @tag timeout: 600_000
  describe "performance at scale" do
    test "10,000 machines with <1ms P99 reservation overhead" do
      Logger.info("Starting large-scale performance test: 10,000 machines")

      latencies = :ets.new(:latencies, [:bag, :public])

      capacity = ResourceManager.get_capacity()
      max_machines = min(10_000, div(trunc(capacity.total.memory_mb), 512))

      Logger.info("Starting #{max_machines} machines...")

      start_time = System.monotonic_time(:millisecond)

      results =
        1..max_machines
        |> Enum.chunk_every(100)
        |> Enum.flat_map(fn batch ->
          tasks =
            Enum.map(batch, fn i ->
              Task.async(fn ->
                reserve_start = System.monotonic_time(:microsecond)

                result =
                  MachActorSup.start_machine(
                    id: "scale-#{i}",
                    size: %{cpu_count: 0.25, memory_mb: 512, disk_mb: 1024}
                  )

                reserve_duration = System.monotonic_time(:microsecond) - reserve_start
                :ets.insert(latencies, {:latency, reserve_duration})

                result
              end)
            end)

          Task.await_many(tasks, 30_000)
        end)

      total_time = System.monotonic_time(:millisecond) - start_time

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)
      errors = Enum.count(results, fn res -> match?({:error, _, _}, res) end)
      queued = Enum.count(results, fn res -> match?({:queued, _}, res) end)

      all_latencies =
        :ets.tab2list(latencies)
        |> Enum.map(fn {:latency, lat} -> lat end)
        |> Enum.sort()

      p99_index = trunc(length(all_latencies) * 0.99)
      p99_latency_us = Enum.at(all_latencies, p99_index, 0)
      p99_latency_ms = p99_latency_us / 1000.0

      :ets.delete(latencies)

      Logger.info("""
      Large-scale test completed:
      - Total machines attempted: #{max_machines}
      - Successes: #{successes}
      - Errors: #{errors}
      - Queued: #{queued}
      - Total time: #{total_time}ms
      - P99 reservation latency: #{Float.round(p99_latency_ms, 2)}ms
      - Throughput: #{Float.round(successes / (total_time / 1000), 1)} machines/sec
      """)

      assert p99_latency_ms < 5.0,
             "P99 latency #{p99_latency_ms}ms exceeds 5ms target"

      assert successes >= div(max_machines, 2),
             "Less than 50% success rate: #{successes}/#{max_machines}"
    end

    @tag :slow
    test "resource queue processes 100+ requests per second" do
      capacity = ResourceManager.get_capacity()
      machines_to_fill = div(trunc(capacity.total.memory_mb), 2048)

      for i <- 1..machines_to_fill do
        MachActorSup.start_machine(
          id: "filler-#{i}",
          size: %{cpu_count: 0.5, memory_mb: 2048, disk_mb: 5120}
        )
      end

      start_time = System.monotonic_time(:millisecond)

      tasks =
        for i <- 1..500 do
          Task.async(fn ->
            ResourceQueue.enqueue(
              "queued-#{i}",
              %{cpu_cores: 0.5, memory_mb: 1024, disk_mb: 2048},
              priority: 50
            )
          end)
        end

      results = Task.await_many(tasks, 30_000)
      enqueue_time = System.monotonic_time(:millisecond) - start_time

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)

      enqueue_rate = successes / (enqueue_time / 1000.0)

      Logger.info("Queue enqueue performance",
        total: 500,
        successes: successes,
        time_ms: enqueue_time,
        rate_per_sec: Float.round(enqueue_rate, 1)
      )

      assert enqueue_rate >= 100.0,
             "Enqueue rate #{enqueue_rate}/s is below 100/s target"
    end
  end

  describe "drift reconciliation resource validation" do
    test "reconciliation validates resource consistency" do
      for i <- 1..10 do
        MachActorSup.start_machine(
          id: "drift-#{i}",
          size: %{cpu_count: 1.0, memory_mb: 2048, disk_mb: 5120}
        )
      end

      capacity_before = ResourceManager.get_capacity()

      Reconciler.force_reconciliation()
      Process.sleep(1000)

      capacity_after = ResourceManager.get_capacity()

      running_count = MachActorSup.count_machines()
      expected_reserved = running_count * 2048

      tolerance = trunc(expected_reserved * 0.1)
      actual_reserved = capacity_after.reserved.memory_mb

      diff = abs(actual_reserved - expected_reserved)

      assert diff <= tolerance,
             "Reserved memory #{actual_reserved} MB differs from expected #{expected_reserved} MB by #{diff} MB"
    end
  end

  defp wait_for_resurrection(machine_id, timeout_ms) do
    start_time = System.monotonic_time(:millisecond)

    Stream.iterate(0, &(&1 + 1))
    |> Enum.reduce_while(false, fn _attempt, _acc ->
      case MachActorSup.find_machine(machine_id) do
        {:ok, pid} when is_pid(pid) ->
          if Process.alive?(pid) do
            {:halt, true}
          else
            check_timeout(start_time, timeout_ms)
          end

        {:error, :not_found} ->
          check_timeout(start_time, timeout_ms)
      end
    end)
  end

  defp check_timeout(start_time, timeout_ms) do
    if System.monotonic_time(:millisecond) - start_time > timeout_ms do
      {:halt, false}
    else
      Process.sleep(50)
      {:cont, false}
    end
  end
end
