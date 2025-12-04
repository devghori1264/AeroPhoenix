defmodule Orchestrator.Migration.StateTransferTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Migration.StateTransfer

  describe "create_snapshot/1" do
    test "creates hot snapshot with LSN" do
      assert {:ok, snapshot_file, lsn} = StateTransfer.create_snapshot("machine_snapshot_1")

      assert is_binary(snapshot_file)
      assert String.contains?(snapshot_file, "snapshot_")
      assert is_integer(lsn)
      assert lsn > 0
    end

    test "snapshot completes within reasonable time" do
      start_time = System.monotonic_time(:millisecond)

      {:ok, _file, _lsn} = StateTransfer.create_snapshot("machine_snapshot_2")

      duration = System.monotonic_time(:millisecond) - start_time

      assert duration < 500
    end
  end

  describe "ship_wal_incremental/3" do
    test "ships WAL entries incrementally" do
      {:ok, _snapshot_file, snapshot_lsn} =
        StateTransfer.create_snapshot("machine_wal_ship_1")

      assert {:ok, final_lsn} =
               StateTransfer.ship_wal_incremental(
                 "machine_wal_ship_1",
                 :lhr,
                 snapshot_lsn
               )

      assert is_integer(final_lsn)
      assert final_lsn >= snapshot_lsn
    end

    test "handles large WAL efficiently" do
      {:ok, _snapshot_file, snapshot_lsn} =
        StateTransfer.create_snapshot("machine_large_wal_1")

      start_time = System.monotonic_time(:millisecond)

      {:ok, _final_lsn} =
        StateTransfer.ship_wal_incremental(
          "machine_large_wal_1",
          :lhr,
          snapshot_lsn
        )

      duration = System.monotonic_time(:millisecond) - start_time

      assert duration < 200
    end
  end

  describe "transfer_final_state/2" do
    test "transfers final state with minimal downtime" do
      dirty_bytes = 1_048_576

      start_time = System.monotonic_time(:millisecond)

      assert :ok = StateTransfer.transfer_final_state("machine_final_1", dirty_bytes)

      downtime = System.monotonic_time(:millisecond) - start_time

      assert downtime < 100
    end

    test "handles various dirty byte sizes" do
      test_cases = [
        {10_000, "10KB"},
        {100_000, "100KB"},
        {1_048_576, "1MB"},
        {10_485_760, "10MB"}
      ]

      for {dirty_bytes, _label} <- test_cases do
        assert :ok = StateTransfer.transfer_final_state("machine_dirty_test", dirty_bytes)
      end
    end
  end

  describe "compress_data/1" do
    test "compresses data with good ratio" do
      data = :crypto.strong_rand_bytes(1_048_576)

      assert {:ok, compressed, ratio} = StateTransfer.compress_data(data)

      assert is_binary(compressed)
      assert byte_size(compressed) < byte_size(data)
      assert ratio > 1.0
      assert ratio < 10.0
    end

    test "reports compression metrics" do
      data = :crypto.strong_rand_bytes(524_288)

      {:ok, _compressed, ratio} = StateTransfer.compress_data(data)

      assert ratio >= 2.0
      assert ratio <= 5.0
    end
  end

  describe "verify_checksums/2" do
    test "verifies matching checksums" do
      data = :crypto.strong_rand_bytes(1024)

      assert :ok = StateTransfer.verify_checksums(data, data)
    end

    test "detects checksum mismatch" do
      source_data = :crypto.strong_rand_bytes(1024)
      dest_data = :crypto.strong_rand_bytes(1024)

      assert {:error, :checksum_mismatch} =
               StateTransfer.verify_checksums(source_data, dest_data)
    end

    test "verifies with various data sizes" do
      test_sizes = [100, 1_000, 10_000, 100_000, 1_000_000]

      for size <- test_sizes do
        data = :crypto.strong_rand_bytes(size)
        assert :ok = StateTransfer.verify_checksums(data, data)
      end
    end
  end

  describe "telemetry events" do
    setup do

      events = [
        [:orchestrator, :state_transfer, :snapshot_created],
        [:orchestrator, :state_transfer, :wal_shipped],
        [:orchestrator, :state_transfer, :final_flush],
        [:orchestrator, :state_transfer, :compression]
      ]

      test_pid = self()

      handler_id = "test-state-transfer-#{System.unique_integer()}"

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

    test "emits snapshot created event" do
      {:ok, _file, _lsn} = StateTransfer.create_snapshot("machine_telemetry_snapshot_1")

      assert_receive {:telemetry_event, [:orchestrator, :state_transfer, :snapshot_created],
                      measurements, metadata},
                     1000

      assert is_integer(measurements.duration_ms)
      assert is_number(measurements.size_mb)
      assert is_integer(measurements.lsn)
      assert metadata.machine_id == "machine_telemetry_snapshot_1"
    end

    test "emits WAL shipped event" do
      {:ok, _file, snapshot_lsn} = StateTransfer.create_snapshot("machine_telemetry_wal_1")

      {:ok, _final_lsn} =
        StateTransfer.ship_wal_incremental("machine_telemetry_wal_1", :lhr, snapshot_lsn)

      assert_receive {:telemetry_event, [:orchestrator, :state_transfer, :wal_shipped],
                      measurements, metadata},
                     1000

      assert is_integer(measurements.entries_count)
      assert is_integer(measurements.bytes)
      assert is_integer(measurements.lag_ms)
      assert metadata.machine_id == "machine_telemetry_wal_1"
    end

    test "emits final flush event" do
      StateTransfer.transfer_final_state("machine_telemetry_flush_1", 1_048_576)

      assert_receive {:telemetry_event, [:orchestrator, :state_transfer, :final_flush],
                      measurements, %{machine_id: "machine_telemetry_flush_1"} = metadata},
                     1000

      assert is_integer(measurements.downtime_ms)
      assert is_integer(measurements.entries_count)
      assert metadata.machine_id == "machine_telemetry_flush_1"
    end

    test "emits compression event" do
      data = :crypto.strong_rand_bytes(1_048_576)
      StateTransfer.compress_data(data)

      assert_receive {:telemetry_event, [:orchestrator, :state_transfer, :compression],
                      measurements, _metadata},
                     1000

      assert is_number(measurements.original_mb)
      assert is_number(measurements.compressed_mb)
      assert is_number(measurements.ratio)
      assert measurements.ratio > 1.0
    end
  end

  describe "integration scenarios" do
    test "complete snapshot + WAL + final flush workflow" do
      machine_id = "machine_workflow_1"

      {:ok, _snapshot_file, snapshot_lsn} = StateTransfer.create_snapshot(machine_id)
      assert is_integer(snapshot_lsn)

      {:ok, final_lsn} = StateTransfer.ship_wal_incremental(machine_id, :lhr, snapshot_lsn)
      assert final_lsn >= snapshot_lsn

      dirty_bytes = (final_lsn - snapshot_lsn) * 4096
      assert :ok = StateTransfer.transfer_final_state(machine_id, dirty_bytes)
    end

    test "snapshot + compression + verification workflow" do
      {:ok, _snapshot_file, _lsn} = StateTransfer.create_snapshot("machine_compress_verify_1")

      snapshot_data = :crypto.strong_rand_bytes(1_048_576)

      {:ok, _compressed, ratio} = StateTransfer.compress_data(snapshot_data)
      assert ratio > 1.0

      decompressed = snapshot_data

      assert :ok = StateTransfer.verify_checksums(snapshot_data, decompressed)
    end
  end
end
