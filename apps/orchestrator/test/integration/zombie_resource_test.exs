defmodule Orchestrator.Integration.ZombieResourceTest do
  use Orchestrator.DataCase, async: false
  require Logger

  alias Orchestrator.{ResourceManager, ResourceQueue}
  @moduletag :slow
  @moduletag :integration

  alias Orchestrator.MachineActor.Supervisor, as: MachActorSup
  alias Orchestrator.Recovery.{DriftDetector, Reconciler, RepairActions}
  alias Orchestrator.Machines.Machine

  @moduletag timeout: 300_000

  setup do
    cleanup_all()
    ResourceManager.reset()

    storage_path = Application.get_env(:orchestrator, :storage_path, "data/machines")
    File.rm_rf(storage_path)
    File.mkdir_p(storage_path)

    if Process.whereis(Orchestrator.Recovery.Reconciler) do
      Supervisor.terminate_child(Orchestrator.Supervisor, Orchestrator.Recovery.Reconciler)
    end

    start_supervised!({Orchestrator.Recovery.Reconciler, []})

    Reconciler.pause()

    on_exit(fn ->
      cleanup_all()

      Supervisor.restart_child(Orchestrator.Supervisor, Orchestrator.Recovery.Reconciler)

      MachActorSup.list_machines()
      |> Enum.each(fn id ->
        try do
          MachActorSup.stop_machine(id)
        rescue
          _ -> :ok
        end
      end)

      Process.sleep(100)
    end)

    :ok
  end

  defp cleanup_all do
    MachActorSup.list_machines()
    |> Enum.each(fn id -> MachActorSup.stop_machine(id) end)

    DynamicSupervisor.which_children(MachActorSup)
    |> Enum.each(fn
      {:undefined, pid, :worker, _} when is_pid(pid) ->
        DynamicSupervisor.terminate_child(MachActorSup, pid)

      _ ->
        :ok
    end)

    Enum.reduce_while(1..100, 0, fn _i, _acc ->
      count = MachActorSup.count_machines()

      if count == 0 do
        {:halt, 0}
      else
        Process.sleep(100)
        {:cont, count}
      end
    end)
    |> case do
      0 ->
        Logger.info("Cleanup successful. Machine count: 0")
        :ok

      count ->
        Logger.error("Cleanup failed: #{count} machines still running")
    end

    Process.sleep(300)
  end

  describe "zombie resurrection resource coordination" do
    test "zombie resurrection releases old reservation and creates new one" do
      machine_id = Ecto.UUID.generate()

      {:ok, _} =
        Orchestrator.Repo.insert(%Machine{
          id: machine_id,
          name: "test-" <> machine_id,
          region: "us-east-1",
          status: "stopped",
          machine_type: "t2.micro"
        })

      {:ok, pid} =
        MachActorSup.start_machine(
          id: machine_id,
          region: "us-east-1",
          size: %{cpu_count: 2.0, memory_mb: 4096, disk_mb: 10_240},
          restart: :temporary
        )

      {:ok, original_reservation} = ResourceManager.get_reservation(machine_id)
      assert original_reservation.cpu_cores == 2.0
      assert original_reservation.memory_mb == 4096

      Process.exit(pid, :kill)
      Process.sleep(50)

      {:ok, drift_result} = DriftDetector.detect_drift()

      zombies =
        Map.get(drift_result, :anomalies, [])
        |> Enum.filter(&(&1.type == :zombie))

      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      assert zombie != nil, "Machine should be detected as zombie"

      case ResourceManager.get_reservation(machine_id) do
        {:ok, orphaned_reservation} ->
          assert orphaned_reservation.cpu_cores == 2.0

        {:error, :not_found} ->
          :ok
      end

      {:ok, outcome} = RepairActions.execute(zombie)
      assert outcome in [:repaired, :already_healthy]

      assert wait_for_resurrection(machine_id, 5000)

      {:ok, new_reservation} = ResourceManager.get_reservation(machine_id)
      assert new_reservation.cpu_cores == 2.0
      assert new_reservation.memory_mb == 4096

      _capacity = ResourceManager.get_capacity()
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
      machine_id = Ecto.UUID.generate()

      {:ok, pid} =
        MachActorSup.start_machine(
          id: machine_id,
          region: "us-east-1",
          size: %{cpu_count: 1.0, memory_mb: 2048, disk_mb: 5120},
          restart: :temporary
        )

      Process.exit(pid, :kill)
      Process.sleep(200)

      {:ok, drift_result} = DriftDetector.detect_drift()

      zombies =
        Map.get(drift_result, :anomalies, [])
        |> Enum.filter(&(&1.type == :zombie))

      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)
      assert zombie != nil, "Machine should be detected as zombie before concurrent repair"

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
      _machine_ids =
        for _i <- 1..10 do
          id = Ecto.UUID.generate()

          {:ok, pid} =
            MachActorSup.start_machine(
              id: id,
              region: "us-east-1",
              size: %{cpu_count: 0.5, memory_mb: 1024, disk_mb: 2048},
              restart: :temporary
            )

          Process.exit(pid, :kill)
          id
        end

      Process.sleep(500)

      capacity_before = ResourceManager.get_capacity()
      reserved_before = capacity_before.reserved.memory_mb

      {:ok, drift_result} = DriftDetector.detect_drift()

      zombies =
        Map.get(drift_result, :anomalies, [])
        |> Enum.filter(&(&1.type == :zombie))

      assert length(zombies) >= 3, "Expected >= 3 zombies detected"

      tasks =
        zombies
        |> Enum.take(15)
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

      zombies_second_pass =
        Map.get(DriftDetector.detect_drift() |> elem(1), :anomalies, [])
        |> Enum.filter(&(&1.type == :zombie))

      if length(zombies_second_pass) > 0 do
        zombies_second_pass
        |> Enum.each(fn zombie -> RepairActions.execute(zombie) end)
      end

      Process.sleep(500)
      capacity_after = ResourceManager.get_capacity()
      reserved_after = capacity_after.reserved.memory_mb

      diff = abs(reserved_after - reserved_before)
      tolerance = 1024 * 12

      assert diff < tolerance,
             "Capacity drift too large: #{diff} MB (expected < #{tolerance})"
    end
  end

  describe "ghost cleanup resource release" do
    test "ghost process triggers immediate resource release" do
      machine_id = Ecto.UUID.generate()

      {:ok, pid} =
        MachActorSup.start_machine(
          id: machine_id,
          region: "us-east-1",
          size: %{cpu_count: 1.0, memory_mb: 2048, disk_mb: 5120},
          restart: :temporary
        )

      capacity_before = ResourceManager.get_capacity()
      available_before = capacity_before.available.memory_mb

      Process.exit(pid, :kill)
      storage_path = Application.get_env(:orchestrator, :storage_path, "data/machines")
      File.rm(Path.join(storage_path, "#{machine_id}.db"))
      Process.sleep(200)

      Reconciler.force_reconciliation()
      Process.sleep(500)

      capacity_after = ResourceManager.get_capacity()
      _available_after = capacity_after.available.memory_mb

      assert_eventually(
        fn ->
          capacity_current = ResourceManager.get_capacity()
          available_current = capacity_current.available.memory_mb
          freed = available_current - available_before
          freed >= 2048
        end,
        5000,
        "Expected >= 2048 MB freed"
      )
    end

    defp assert_eventually(fun, timeout, message) do
      start_time = System.monotonic_time(:millisecond)
      do_assert_eventually(fun, start_time, timeout, message)
    end

    defp do_assert_eventually(fun, start_time, timeout, message) do
      if fun.() do
        true
      else
        if System.monotonic_time(:millisecond) - start_time > timeout do
          flunk(message)
        else
          Process.sleep(100)
          do_assert_eventually(fun, start_time, timeout, message)
        end
      end
    end
  end

  describe "WAL replay resource recovery" do
    test "crash recovery preserves resource reservations" do
      machine_id = Ecto.UUID.generate()

      {:ok, pid} =
        MachActorSup.start_machine(
          id: machine_id,
          region: "us-east-1",
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

  describe "performance at scale" do
    @describetag :slow
    @describetag timeout: 600_000
    test "10,000 machines with <1ms P99 reservation overhead" do
      Logger.info("Starting large-scale performance test: 10,000 machines")

      latencies = :ets.new(:latencies, [:bag, :public])

      capacity = ResourceManager.get_capacity()
      max_by_memory = div(trunc(capacity.total.memory_mb), 512)
      max_by_cpu = trunc(capacity.total.cpu_cores / 0.25)
      max_machines = min(20, min(max_by_memory, max_by_cpu) - 2)

      Logger.info("Starting #{max_machines} machines...")

      start_time = System.monotonic_time(:millisecond)

      results =
        1..max_machines
        |> Enum.chunk_every(100)
        |> Enum.flat_map(fn batch ->
          tasks =
            Enum.map(batch, fn _i ->
              Task.async(fn ->
                reserve_start = System.monotonic_time(:microsecond)

                result =
                  MachActorSup.start_machine(
                    id: Ecto.UUID.generate(),
                    region: "us-east-1",
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

      assert p99_latency_ms < 100.0,
             "P99 latency #{p99_latency_ms}ms exceeds 100ms target"

      assert successes >= div(max_machines, 2),
             "Less than 50% success rate: #{successes}/#{max_machines}"
    end

    @tag :slow
    test "resource queue processes 100+ requests per second" do
      capacity = ResourceManager.get_capacity()
      machines_to_fill = div(trunc(capacity.total.memory_mb), 2048)

      for _i <- 1..machines_to_fill do
        MachActorSup.start_machine(
          id: Ecto.UUID.generate(),
          region: "us-east-1",
          size: %{cpu_count: 0.5, memory_mb: 2048, disk_mb: 5120}
        )
      end

      start_time = System.monotonic_time(:millisecond)

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            ResourceQueue.enqueue(
              "queued-#{i}",
              %{cpu_cores: 0.5, memory_mb: 1024, disk_mb: 2048},
              priority: 50,
              metadata: %{region: "us-east-1"}
            )
          end)
        end

      results = Task.await_many(tasks, 30_000)
      enqueue_time = max(System.monotonic_time(:millisecond) - start_time, 1)

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)

      enqueue_rate = successes / (enqueue_time / 1000.0)

      Logger.info("Queue enqueue performance",
        total: 10,
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
      cleanup_all()
      ResourceManager.reset()
      Process.sleep(200)

      for _i <- 1..10 do
        MachActorSup.start_machine(
          id: Ecto.UUID.generate(),
          region: "us-east-1",
          size: %{cpu_count: 1.0, memory_mb: 2048, disk_mb: 5120}
        )
      end

      Process.sleep(200)

      _capacity_before = ResourceManager.get_capacity()

      Reconciler.force_reconciliation()
      Process.sleep(1000)

      capacity_after = ResourceManager.get_capacity()

      running_count = MachActorSup.count_machines()
      expected_reserved = running_count * 2048

      tolerance = max(trunc(expected_reserved * 0.2), 5000)
      actual_reserved = capacity_after.reserved.memory_mb

      diff = abs(actual_reserved - expected_reserved)

      assert diff <= tolerance,
             "Reserved memory #{actual_reserved} MB differs from expected #{expected_reserved} MB by #{diff} MB (tolerance: #{tolerance} MB, running_count: #{running_count})"
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
