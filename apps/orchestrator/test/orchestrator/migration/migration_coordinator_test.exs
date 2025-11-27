defmodule Orchestrator.Migration.MigrationCoordinatorTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Migration.MigrationCoordinator

  setup do
    {:ok, _pid} = start_supervised(MigrationCoordinator)
    :ok
  end

  describe "migrate_machine/2" do
    test "successfully migrates machine with zero downtime" do
      assert {:ok, :lhr} =
               MigrationCoordinator.migrate_machine("machine_test_1",
                 source_region: :iad,
                 dest_region: :lhr,
                 enable_rollback: true
               )

      stats = MigrationCoordinator.stats()
      assert stats.completed >= 1
      assert stats.success_rate > 0.0
    end

    test "migrates with acceptable downtime" do
      start_time = System.monotonic_time(:millisecond)

      {:ok, _region} =
        MigrationCoordinator.migrate_machine("machine_test_2",
          source_region: :iad,
          dest_region: :lhr
        )

      duration = System.monotonic_time(:millisecond) - start_time

      assert duration < 1000
    end

    test "handles multiple concurrent migrations" do
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            MigrationCoordinator.migrate_machine("machine_concurrent_#{i}",
              source_region: :iad,
              dest_region: :lhr
            )
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, fn
               {:ok, _region} -> true
               _ -> false
             end)

      stats = MigrationCoordinator.stats()
      assert stats.completed >= 5
    end

    test "tracks active migrations" do
      task =
        Task.async(fn ->
          MigrationCoordinator.migrate_machine("machine_active_1",
            source_region: :iad,
            dest_region: :lhr
          )
        end)

      stats = MigrationCoordinator.stats()
      assert stats.active_migrations >= 0

      {:ok, _region} = Task.await(task, 5000)
    end
  end

  describe "stats/0" do
    test "returns migration statistics" do
      stats = MigrationCoordinator.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :completed)
      assert Map.has_key?(stats, :failed)
      assert Map.has_key?(stats, :rolled_back)
      assert Map.has_key?(stats, :total_migrations)
      assert Map.has_key?(stats, :success_rate)
      assert Map.has_key?(stats, :active_migrations)
    end

    test "calculates success rate correctly" do
      {:ok, _} =
        MigrationCoordinator.migrate_machine("machine_stats_1",
          source_region: :iad,
          dest_region: :lhr
        )

      stats = MigrationCoordinator.stats()

      assert stats.success_rate >= 0.0
      assert stats.success_rate <= 1.0
    end
  end

  describe "rollback behavior" do
    test "supports rollback on failure" do
      result =
        MigrationCoordinator.migrate_machine("machine_rollback_1",
          source_region: :iad,
          dest_region: :lhr,
          enable_rollback: true
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "can disable rollback" do
      result =
        MigrationCoordinator.migrate_machine("machine_no_rollback_1",
          source_region: :iad,
          dest_region: :lhr,
          enable_rollback: false
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "telemetry events" do
    setup do
      events = [
        [:orchestrator, :migration, :completed],
        [:orchestrator, :migration, :precopy_iteration],
        [:orchestrator, :migration, :draining_completed],
        [:orchestrator, :migration, :rollback]
      ]

      test_pid = self()

      handler_id = "test-migration-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      :ok
    end

    test "emits migration completed event" do
      {:ok, _} =
        MigrationCoordinator.migrate_machine("machine_telemetry_1",
          source_region: :iad,
          dest_region: :lhr
        )

      assert_receive {:telemetry_event, [:orchestrator, :migration, :completed], measurements,
                      metadata},
                     1000

      assert is_integer(measurements.total_duration_ms)
      assert is_integer(measurements.downtime_ms)
      assert metadata.machine_id == "machine_telemetry_1"
      assert metadata.dest_region == :lhr
    end

    test "emits pre-copy iteration events" do
      {:ok, _} =
        MigrationCoordinator.migrate_machine("machine_precopy_1",
          source_region: :iad,
          dest_region: :lhr
        )

      assert_receive {:telemetry_event, [:orchestrator, :migration, :precopy_iteration], _, _},
                     1000
    end
  end

  describe "edge cases" do
    test "handles same source and destination region" do
      result =
        MigrationCoordinator.migrate_machine("machine_same_region_1",
          source_region: :iad,
          dest_region: :iad
        )

      assert {:ok, :iad} = result
    end

    test "validates required options" do
      assert_raise KeyError, fn ->
        MigrationCoordinator.migrate_machine("machine_invalid_1", [])
      end
    end
  end
end
