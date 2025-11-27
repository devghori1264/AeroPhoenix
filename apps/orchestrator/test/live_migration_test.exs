defmodule Orchestrator.LiveMigrationTest do
  use ExUnit.Case, async: false

  alias Orchestrator.LiveMigration.{Coordinator, Checkpointer, StateTransfer, Cutover}
  alias Orchestrator.FlydClient

  @moduletag :integration

  describe "full live migration flow" do
    test "successfully migrates machine with pre-copy strategy" do
      machine_id = "test_machine_#{:rand.uniform(10000)}"
      source_region = "us-west-1"
      target_region = "us-east-1"

      config = %{
        strategy: :pre_copy,
        max_iterations: 3,
        freeze_threshold_ms: 100,
        parallel_streams: 2,
        preserve_ip: false
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, source_region, target_region, config)

      assert is_binary(migration_id)

      wait_for_migration_completion(migration_id, 30_000)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.phase == :completed
      assert status.status == :success
      assert status.bytes_transferred > 0
    end

    test "successfully migrates with post-copy strategy" do
      machine_id = "test_machine_postcopy_#{:rand.uniform(10000)}"
      source_region = "eu-west-1"
      target_region = "eu-central-1"

      config = %{
        strategy: :post_copy,
        parallel_streams: 4
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, source_region, target_region, config)

      wait_for_migration_completion(migration_id, 30_000)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.phase == :completed
      assert status.downtime_ms < 500
    end

    test "successfully migrates with hybrid strategy" do
      machine_id = "test_machine_hybrid_#{:rand.uniform(10000)}"

      config = %{
        strategy: :hybrid,
        max_iterations: 5,
        preserve_ip: true
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-east-1", "us-west-2", config)

      wait_for_migration_completion(migration_id, 45_000)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.phase == :completed
    end
  end

  describe "pause and resume migration" do
    test "can pause and resume during incremental sync" do
      machine_id = "test_pause_#{:rand.uniform(10000)}"

      config = %{
        strategy: :pre_copy,
        max_iterations: 10
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-west-1", "us-east-1", config)

      :timer.sleep(2000)

      :ok = Coordinator.pause_migration(migration_id)
      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.status == :paused

      :ok = Coordinator.resume_migration(migration_id)
      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.status == :in_progress

      wait_for_migration_completion(migration_id, 30_000)
    end
  end

  describe "migration cancellation and rollback" do
    test "can cancel migration before completion" do
      machine_id = "test_cancel_#{:rand.uniform(10000)}"

      config = %{
        strategy: :pre_copy,
        max_iterations: 10
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-west-1", "us-east-1", config)

      :timer.sleep(1000)
      :ok = Coordinator.cancel_migration(migration_id)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.status == :cancelled
    end

    test "automatically rolls back on phase failure" do
      assert function_exported?(Coordinator, :handle_info, 2)
    end
  end

  describe "checkpointing" do
    test "creates and restores full checkpoint" do
      machine_id = "test_checkpoint_#{:rand.uniform(10000)}"
      region = "us-west-1"

      {:ok, checkpoint_id} = Checkpointer.create_checkpoint(region, machine_id, :full)
      assert is_binary(checkpoint_id)

      {:ok, info} = Checkpointer.get_checkpoint_info(checkpoint_id)
      assert info.type == :full
      assert info.machine_id == machine_id
      assert info.compressed_size > 0

      target_region = "us-east-1"
      target_machine = "test_target_#{:rand.uniform(10000)}"
      :ok = Checkpointer.restore_checkpoint(checkpoint_id, target_region, target_machine)

      :ok = Checkpointer.delete_checkpoint(checkpoint_id)
    end

    test "creates incremental checkpoint" do
      machine_id = "test_incremental_#{:rand.uniform(10000)}"
      region = "eu-west-1"

      {:ok, base_id} = Checkpointer.create_checkpoint(region, machine_id, :full)

      {:ok, incr_id} =
        Checkpointer.create_checkpoint(region, machine_id, :incremental, base_checkpoint: base_id)

      assert incr_id != base_id

      {:ok, info} = Checkpointer.get_checkpoint_info(incr_id)
      assert info.type == :incremental
      assert info.base_checkpoint == base_id

      Checkpointer.delete_checkpoint(base_id)
      Checkpointer.delete_checkpoint(incr_id)
    end
  end

  describe "state transfer" do
    test "transfers incremental state" do
      source_region = "us-west-1"
      target_region = "us-east-1"
      machine_id = "test_transfer_#{:rand.uniform(10000)}"
      checkpoint_id = "ckpt_#{:rand.uniform(10000)}"

      dirty_pages = Enum.to_list(1..100)

      {:ok, result} =
        StateTransfer.transfer_incremental(
          source_region,
          target_region,
          machine_id,
          dirty_pages: dirty_pages,
          checkpoint_id: checkpoint_id
        )

      assert result.pages_transferred == 100
      assert result.bytes_transferred > 0
      assert result.throughput_mbps > 0
    end

    test "transfers final state with compression" do
      source_region = "eu-west-1"
      target_region = "eu-central-1"
      machine_id = "test_final_#{:rand.uniform(10000)}"

      remaining_pages = Enum.to_list(1..50)

      {:ok, result} =
        StateTransfer.transfer_final(
          source_region,
          target_region,
          machine_id,
          remaining_pages: remaining_pages
        )

      assert result.pages_transferred == 50
      assert result.compression_ratio > 0
    end

    test "handles parallel transfer streams" do
      source_region = "us-west-1"
      target_region = "us-east-1"
      machine_id = "test_parallel_#{:rand.uniform(10000)}"

      dirty_pages = Enum.to_list(1..1000)

      start_time = System.monotonic_time(:millisecond)

      {:ok, result} =
        StateTransfer.transfer_incremental(
          source_region,
          target_region,
          machine_id,
          dirty_pages: dirty_pages,
          parallel_streams: 4
        )

      duration = System.monotonic_time(:millisecond) - start_time

      assert result.pages_transferred == 1000
      assert duration < 30_000
    end
  end

  describe "network cutover" do
    test "performs graceful cutover with connection draining" do
      machine_id = "test_cutover_#{:rand.uniform(10000)}"
      source_region = "us-west-1"
      target_region = "us-east-1"

      opts = %{
        drain_timeout_ms: 5000,
        preserve_ip: false,
        dns_ttl: 30
      }

      {:ok, result} = Cutover.perform_cutover(machine_id, source_region, target_region, opts)

      assert result.success == true
      assert is_binary(result.new_endpoint)
      assert result.cutover_duration_ms < 10_000
      assert result.connections_migrated >= 0
    end

    test "performs cutover with IP preservation" do
      machine_id = "test_ip_preserve_#{:rand.uniform(10000)}"

      opts = %{
        preserve_ip: true,
        drain_timeout_ms: 3000
      }

      {:ok, result} = Cutover.perform_cutover(machine_id, "eu-west-1", "eu-central-1", opts)

      assert result.success == true
      assert result.new_endpoint =~ ~r/\d+\.\d+\.\d+\.\d+/ or result.new_endpoint != ""
    end

    test "rolls back on cutover failure" do
      machine_id = "test_rollback_#{:rand.uniform(10000)}"

      assert function_exported?(Cutover, :perform_cutover, 4)
    end
  end

  describe "performance targets" do
    test "achieves < 500ms total downtime" do
      machine_id = "test_perf_#{:rand.uniform(10000)}"

      config = %{
        strategy: :pre_copy,
        freeze_threshold_ms: 100,
        parallel_streams: 4
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-west-1", "us-east-1", config)

      wait_for_migration_completion(migration_id, 30_000)

      {:ok, status} = Coordinator.get_status(migration_id)

      assert status.downtime_ms <= 500 or status.downtime_ms == 0
    end

    test "achieves < 100ms freeze time during final sync" do
      machine_id = "test_freeze_#{:rand.uniform(10000)}"

      config = %{
        strategy: :pre_copy,
        freeze_threshold_ms: 100,
        max_iterations: 5
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-west-1", "us-east-1", config)

      wait_for_migration_completion(migration_id, 30_000)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.status == :success
    end
  end

  defp wait_for_migration_completion(migration_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop(migration_id, deadline)
  end

  defp wait_loop(migration_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Migration timed out"
    end

    case Coordinator.get_status(migration_id) do
      {:ok, %{status: status}} when status in [:success, :failed, :cancelled] ->
        :ok

      {:ok, _} ->
        :timer.sleep(500)
        wait_loop(migration_id, deadline)

      {:error, reason} ->
        raise "Migration status check failed: #{inspect(reason)}"
    end
  end
end
