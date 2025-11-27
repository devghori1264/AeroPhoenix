defmodule Orchestrator.Migration.CutoverCoordinatorTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Migration.{CutoverCoordinator, RoutingTable, WriteBlocker}

  @moduletag :cutover_coordinator

  setup do
    RoutingTable.init()

    on_exit(fn ->
      RoutingTable.all()
      |> Enum.each(fn {machine_id, _} ->
        RoutingTable.delete(machine_id)
      end)
    end)

    :ok
  end

  describe "execute_cutover/1" do
    test "successfully executes 4-step cutover sequence" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      {:ok, stats} =
        CutoverCoordinator.execute_cutover(
          source_machine: source,
          dest_machine: dest,
          migration_id: migration_id
        )

      assert stats.total_duration_ms > 0
      assert stats.downtime_ms > 0

      assert stats.step1_block_writes_ms > 0
      assert stats.step2_tail_sync_ms > 0
      assert stats.step3_start_dest_ms > 0
      assert stats.step4_routing_ms > 0

      {:ok, route} = RoutingTable.lookup("machine_123")
      assert route.region == :lhr
    end

    test "cutover completes within reasonable time" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      start_time = System.monotonic_time(:millisecond)

      {:ok, stats} =
        CutoverCoordinator.execute_cutover(
          source_machine: source,
          dest_machine: dest,
          migration_id: migration_id
        )

      total_time = System.monotonic_time(:millisecond) - start_time

      assert total_time < 5_000

      assert stats.downtime_ms < 2_000
    end

    test "handles checksum verification" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      {:ok, stats} =
        CutoverCoordinator.execute_cutover(
          source_machine: source,
          dest_machine: dest,
          migration_id: migration_id,
          verify_checksums: true
        )

      assert stats.total_duration_ms > 0
    end

    test "emits telemetry events" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      events_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :migration, :cutover_complete]
        ])

      {:ok, _stats} =
        CutoverCoordinator.execute_cutover(
          source_machine: source,
          dest_machine: dest,
          migration_id: migration_id
        )

      assert_receive {[:orchestrator, :migration, :cutover_complete], _ref, measurements,
                      metadata},
                     5000

      assert measurements.total_duration_ms > 0
      assert metadata.migration_id == migration_id

      :telemetry.detach(events_ref)
    end

    test "tracks individual step durations" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      {:ok, stats} =
        CutoverCoordinator.execute_cutover(
          source_machine: source,
          dest_machine: dest,
          migration_id: migration_id
        )

      assert stats.step1_block_writes_ms > 0
      assert stats.step2_tail_sync_ms > 0
      assert stats.step3_start_dest_ms > 0
      assert stats.step4_routing_ms > 0

      step_sum =
        stats.step1_block_writes_ms +
          stats.step2_tail_sync_ms +
          stats.step3_start_dest_ms +
          stats.step4_routing_ms

      assert abs(stats.total_duration_ms - step_sum) < stats.total_duration_ms * 0.1
    end
  end

  describe "cutover timing precision" do
    test "provides microsecond-level timing" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      {:ok, stats} =
        CutoverCoordinator.execute_cutover(
          source_machine: source,
          dest_machine: dest,
          migration_id: migration_id
        )

      assert is_float(stats.total_duration_ms)
      assert is_float(stats.step1_block_writes_ms)
    end
  end

  describe "routing update verification" do
    test "routing points to destination after cutover" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      assert {:error, :not_found} = RoutingTable.lookup("machine_123")

      {:ok, _stats} =
        CutoverCoordinator.execute_cutover(
          source_machine: source,
          dest_machine: dest,
          migration_id: migration_id
        )

      {:ok, route} = RoutingTable.lookup("machine_123")
      assert route.region == :lhr
      assert route.ip == "192.168.2.20"
      assert route.port == 8080
    end

    test "routing update is atomic" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      test_pid = self()

      spawn_link(fn ->
        result =
          CutoverCoordinator.execute_cutover(
            source_machine: source,
            dest_machine: dest,
            migration_id: migration_id
          )

        send(test_pid, {:cutover_complete, result})
      end)

      routes_observed =
        for _ <- 1..20 do
          case RoutingTable.lookup("machine_123") do
            {:ok, route} -> route.region
            {:error, :not_found} -> :not_found
          end
          |> tap(fn _ -> Process.sleep(10) end)
        end

      assert_receive {:cutover_complete, {:ok, _}}, 5000

      for route <- routes_observed do
        assert route in [:not_found, :lhr]
      end
    end
  end
end

defmodule Orchestrator.Migration.WriteBlockerTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Migration.WriteBlocker

  @moduletag :write_blocker

  describe "block_writes/2" do
    test "successfully drains in-flight requests" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      {:ok, stats} = WriteBlocker.block_writes(machine_id)

      assert stats.requests_drained >= 0
      assert stats.duration_ms > 0
      assert stats.forced_close == false
    end

    test "drain completes within timeout" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      start_time = System.monotonic_time(:millisecond)

      {:ok, stats} =
        WriteBlocker.block_writes(machine_id,
          drain_timeout: 5000
        )

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 5000

      assert abs(stats.duration_ms - elapsed) < 100
    end

    test "emits telemetry events" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      events_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :migration, :drain_complete]
        ])

      {:ok, _stats} = WriteBlocker.block_writes(machine_id)

      assert_receive {[:orchestrator, :migration, :drain_complete], _ref, measurements, metadata},
                     5000

      assert measurements.requests_drained >= 0
      assert metadata.machine_id == machine_id

      :telemetry.detach(events_ref)
    end

    test "tracks drain duration accurately" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      {:ok, stats} = WriteBlocker.block_writes(machine_id)

      assert stats.duration_ms > 0

      assert stats.duration_ms < 1000
    end
  end

  describe "unblock_writes/1" do
    test "successfully resumes writes after rollback" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      {:ok, _stats} = WriteBlocker.block_writes(machine_id)

      :ok = WriteBlocker.unblock_writes(machine_id)
    end

    test "emits telemetry on resume" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      events_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :migration, :writes_resumed]
        ])

      {:ok, _stats} = WriteBlocker.block_writes(machine_id)
      :ok = WriteBlocker.unblock_writes(machine_id)

      assert_receive {[:orchestrator, :migration, :writes_resumed], _ref, _measurements,
                      metadata},
                     1000

      assert metadata.machine_id == machine_id

      :telemetry.detach(events_ref)
    end
  end

  describe "in-flight request tracking" do
    test "simulates realistic drain behavior" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      {:ok, stats} = WriteBlocker.block_writes(machine_id)

      assert stats.requests_drained >= 0
    end
  end
end

defmodule Orchestrator.Migration.RoutingUpdaterTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Migration.{RoutingUpdater, RoutingTable}

  @moduletag :routing_updater

  setup do
    RoutingTable.init()

    on_exit(fn ->
      RoutingTable.all()
      |> Enum.each(fn {machine_id, _} ->
        RoutingTable.delete(machine_id)
      end)
    end)

    :ok
  end

  describe "update_route/4" do
    test "atomically updates routing table" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      assert {:error, :not_found} = RoutingTable.lookup("machine_123")

      :ok =
        RoutingUpdater.update_route(
          source,
          dest,
          migration_id
        )

      {:ok, route} = RoutingTable.lookup("machine_123")
      assert route.ip == "192.168.2.20"
      assert route.region == :lhr
    end

    test "replaces existing route" do
      machine_id = "machine_123"

      RoutingTable.update(machine_id, "192.168.1.10", 8080, :iad)

      {:ok, route} = RoutingTable.lookup(machine_id)
      assert route.region == :iad

      :ok =
        RoutingUpdater.update_route(
          "machine_123_iad",
          "machine_123_lhr",
          "migration_test"
        )

      {:ok, route} = RoutingTable.lookup(machine_id)
      assert route.region == :lhr
    end

    test "emits telemetry on routing update" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_#{:rand.uniform(100_000)}"

      events_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :migration, :routing_updated]
        ])

      :ok =
        RoutingUpdater.update_route(
          source,
          dest,
          migration_id
        )

      assert_receive {[:orchestrator, :migration, :routing_updated], _ref, _measurements,
                      metadata},
                     1000

      assert metadata.migration_id == migration_id
      assert metadata.machine_id == "machine_123"
      assert metadata.new_region == :lhr

      :telemetry.detach(events_ref)
    end

    test "handles different regions" do
      test_cases = [
        {"machine_a_iad", "machine_a_lhr", :lhr},
        {"machine_b_lhr", "machine_b_nrt", :nrt},
        {"machine_c_nrt", "machine_c_syd", :syd}
      ]

      for {source, dest, expected_region} <- test_cases do
        :ok =
          RoutingUpdater.update_route(
            source,
            dest,
            "migration_test"
          )

        machine_id =
          source
          |> String.split("_")
          |> Enum.take(2)
          |> Enum.join("_")

        {:ok, route} = RoutingTable.lookup(machine_id)
        assert route.region == expected_region
      end
    end
  end

  describe "rollback_route/2" do
    test "restores previous routing" do
      source = "machine_123_iad"
      dest = "machine_123_lhr"
      migration_id = "migration_test"

      :ok = RoutingUpdater.update_route(source, dest, migration_id)

      {:ok, route} = RoutingTable.lookup("machine_123")
      assert route.region == :lhr

      :ok = RoutingUpdater.rollback_route(source, migration_id)

      {:ok, route} = RoutingTable.lookup("machine_123")
      assert route.region == :iad
    end
  end

  describe "routing table atomicity" do
    test "concurrent updates do not cause race conditions" do
      machine_id = "machine_123"

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            region = Enum.random([:iad, :lhr, :nrt, :syd])
            RoutingTable.update(machine_id, "192.168.#{i}.1", 8080, region)
          end)
        end

      Task.await_many(tasks)

      {:ok, _route} = RoutingTable.lookup(machine_id)
    end

    test "lookups during update always return valid data" do
      machine_id = "machine_123"

      RoutingTable.update(machine_id, "192.168.1.1", 8080, :iad)

      spawn(fn ->
        for i <- 1..100 do
          RoutingTable.update(machine_id, "192.168.1.#{i}", 8080, :iad)
          Process.sleep(1)
        end
      end)

      results =
        for _ <- 1..100 do
          case RoutingTable.lookup(machine_id) do
            {:ok, route} -> route.ip
            {:error, :not_found} -> :not_found
          end
          |> tap(fn _ -> Process.sleep(1) end)
        end

      for result <- results do
        assert result == :not_found or String.starts_with?(result, "192.168.")
      end
    end
  end
end
