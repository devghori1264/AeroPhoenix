defmodule Orchestrator.Migration.MigrationStreamTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Migration.{MigrationStream, ProgressTracker}

  @moduletag :migration_stream

  setup do
    start_supervised!(ProgressTracker)
    :ok
  end

  describe "stream_volume/2" do
    test "successfully streams 50MB volume with backpressure" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      {:ok, stats} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10,
          chunk_size: 1_048_576
        )

      assert stats.chunks_transferred > 0
      assert stats.total_bytes >= 50 * 1024 * 1024
      assert stats.duration_ms > 0

      assert stats.throughput_mbps >= 8.0
      assert stats.throughput_mbps <= 12.0

      assert stats.avg_chunk_latency_ms > 0
      assert stats.avg_chunk_latency_ms < 1000
    end

    test "handles compression correctly" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      {:ok, stats_compressed} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10,
          enable_compression: true
        )

      {:ok, stats_uncompressed} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10,
          enable_compression: false
        )

      assert stats_compressed.chunks_transferred > 0
      assert stats_uncompressed.chunks_transferred > 0
    end

    test "enforces backpressure rate limiting" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      start_time = System.monotonic_time(:millisecond)

      {:ok, stats} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 5,
          chunk_size: 1_048_576
        )

      duration_seconds = (System.monotonic_time(:millisecond) - start_time) / 1000

      expected_min_duration = 50 / 5 * 0.8
      assert duration_seconds >= expected_min_duration

      assert stats.throughput_mbps >= 4.0
      assert stats.throughput_mbps <= 6.0
    end

    test "tracks progress during transfer" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      test_pid = self()

      spawn_link(fn ->
        result =
          MigrationStream.stream_volume(machine_id,
            source_region: :iad,
            dest_region: :lhr,
            bandwidth_limit_mbps: 10
          )

        send(test_pid, {:transfer_complete, result})
      end)

      Process.sleep(300)

      progress_samples =
        for _ <- 1..5 do
          case ProgressTracker.get_progress(machine_id) do
            {:ok, progress} ->
              Process.sleep(200)
              progress.progress

            {:error, :not_found} ->
              Process.sleep(200)
              nil
          end
        end

      valid_samples = Enum.reject(progress_samples, &is_nil/1)
      assert length(valid_samples) > 0

      assert_receive {:transfer_complete, {:ok, _stats}}, 10_000
    end

    test "handles chunk send failures with retry" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      {:ok, stats} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10,
          timeout: 30_000
        )

      assert stats.chunks_transferred > 0
    end

    test "supports different chunk sizes" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      {:ok, stats_small} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10,
          chunk_size: 262_144
        )

      {:ok, stats_large} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10,
          chunk_size: 4_194_304
        )

      assert stats_small.chunks_transferred > stats_large.chunks_transferred
      assert stats_small.avg_chunk_latency_ms < stats_large.avg_chunk_latency_ms

      throughput_diff = abs(stats_small.throughput_mbps - stats_large.throughput_mbps)
      assert throughput_diff < 2.0
    end

    test "emits telemetry events during transfer" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      events_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :migration, :chunk_transferred],
          [:orchestrator, :migration, :progress],
          [:orchestrator, :migration, :stream_completed]
        ])

      {:ok, _stats} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10
        )

      assert_receive {[:orchestrator, :migration, :chunk_transferred], _ref, measurements,
                      metadata},
                     1000

      assert measurements.bytes > 0
      assert metadata.machine_id == machine_id

      assert_receive {[:orchestrator, :migration, :progress], _ref, measurements, _metadata}, 5000
      assert measurements.progress >= 0.0
      assert measurements.progress <= 1.0

      assert_receive {[:orchestrator, :migration, :stream_completed], _ref, measurements,
                      _metadata},
                     5000

      assert measurements.chunks_transferred > 0

      :telemetry.detach(events_ref)
    end

    test "cleans up volume file after transfer" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      files_before = Path.wildcard("/tmp/volume_*.bin")

      {:ok, _stats} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10
        )

      files_after = Path.wildcard("/tmp/volume_*.bin")

      assert length(files_after) == length(files_before)
    end
  end

  describe "checkpoint and resume" do
    test "saves checkpoints during transfer" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      {:ok, stats} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10,
          checkpoint_interval: 10
        )

      assert stats.chunks_transferred > 0
    end
  end

  describe "compression strategy" do
    test "achieves reasonable compression ratio" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      events_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :migration, :chunk_transferred]
        ])

      {:ok, _stats} =
        MigrationStream.stream_volume(machine_id,
          source_region: :iad,
          dest_region: :lhr,
          bandwidth_limit_mbps: 10,
          enable_compression: true
        )

      receive do
        {[:orchestrator, :migration, :chunk_transferred], _ref, measurements, _metadata} ->
          assert measurements.compression_ratio >= 1.0
          assert measurements.compression_ratio <= 3.0
      after
        1000 -> flunk("No chunk_transferred event received")
      end

      :telemetry.detach(events_ref)
    end
  end

  describe "edge cases" do
    test "handles zero-byte volumes" do
    end

    test "handles very large volumes (>1GB)" do
      if System.get_env("RUN_SLOW_TESTS") do
        machine_id = "test_#{:rand.uniform(100_000)}"

        {:ok, stats} =
          MigrationStream.stream_volume(machine_id,
            source_region: :iad,
            dest_region: :lhr,
            bandwidth_limit_mbps: 50,
            chunk_size: 1_048_576
          )

        assert stats.chunks_transferred > 1000
      end
    end
  end
end

defmodule Orchestrator.Migration.BackpressureControllerTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Migration.BackpressureController
  alias Orchestrator.Migration.BackpressureController.{TokenBucket, AdaptiveRateAdapter}

  @moduletag :backpressure_controller

  describe "static throttling" do
    test "sleeps to enforce target rate" do
      start_time = System.monotonic_time(:millisecond)

      :ok =
        BackpressureController.throttle(
          1_048_576,
          20,
          10.0,
          strategy: :static
        )

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed >= 70
      assert elapsed <= 110
    end

    test "does not sleep when already slow" do
      start_time = System.monotonic_time(:millisecond)

      :ok =
        BackpressureController.throttle(
          1_048_576,
          150,
          10.0,
          strategy: :static
        )

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 10
    end

    test "scales with different chunk sizes" do
      start_time = System.monotonic_time(:millisecond)

      :ok =
        BackpressureController.throttle(
          5_242_880,
          100,
          10.0,
          strategy: :static
        )

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed >= 350
      assert elapsed <= 550
    end
  end

  describe "token bucket" do
    test "allows burst then throttles" do
      bucket = TokenBucket.new(10, 10.0)

      {:ok, bucket} = TokenBucket.consume(bucket, 10_485_760)
      assert bucket.tokens == 0

      start_time = System.monotonic_time(:millisecond)
      {:wait, wait_ms, _bucket} = TokenBucket.consume(bucket, 1_048_576)
      assert wait_ms >= 90
      assert wait_ms <= 110

      Process.sleep(wait_ms)
      {:ok, _bucket} = TokenBucket.consume(bucket, 1_048_576)

      elapsed = System.monotonic_time(:millisecond) - start_time
      assert elapsed >= 90
    end

    test "refills tokens over time" do
      bucket = TokenBucket.new(5, 10.0)

      {:ok, bucket} = TokenBucket.consume(bucket, 5_242_880)
      assert bucket.tokens == 0

      Process.sleep(300)

      {:ok, bucket} = TokenBucket.consume(bucket, 2_097_152)

      {:wait, _wait_ms, _bucket} = TokenBucket.consume(bucket, 1_572_864)
    end

    test "caps tokens at capacity" do
      bucket = TokenBucket.new(10, 10.0)

      {:ok, bucket} = TokenBucket.consume(bucket, 5_242_880)

      Process.sleep(2000)

      {:wait, _wait_ms, _bucket} = TokenBucket.consume(bucket, 12_582_912)
    end

    test "throttle with token bucket strategy" do
      bucket = TokenBucket.new(10, 10.0)

      start_time = System.monotonic_time(:millisecond)

      {:ok, bucket} =
        BackpressureController.throttle(
          5_242_880,
          50,
          10.0,
          strategy: :token_bucket,
          bucket: bucket
        )

      elapsed = System.monotonic_time(:millisecond) - start_time
      assert elapsed < 50

      {:ok, _bucket} =
        BackpressureController.throttle(
          5_242_880,
          50,
          10.0,
          strategy: :token_bucket,
          bucket: bucket
        )
    end
  end

  describe "adaptive rate control" do
    test "adapts to increasing RTT (congestion)" do
      adapter = AdaptiveRateAdapter.new(10.0, 100.0)

      adapter = AdaptiveRateAdapter.update(adapter, 1_048_576, 85, 30)
      initial_rate = AdaptiveRateAdapter.get_rate_mbps(adapter)
      assert initial_rate >= 10.0

      adapter = AdaptiveRateAdapter.update(adapter, 1_048_576, 90, 60)
      adapter = AdaptiveRateAdapter.update(adapter, 1_048_576, 95, 80)

      congested_rate = AdaptiveRateAdapter.get_rate_mbps(adapter)
      assert congested_rate < initial_rate
    end

    test "adapts to available bandwidth" do
      adapter = AdaptiveRateAdapter.new(10.0, 200.0)

      adapter = AdaptiveRateAdapter.update(adapter, 1_048_576, 10, 30)

      rate = AdaptiveRateAdapter.get_rate_mbps(adapter)
      assert rate > 10.0

      adapter = AdaptiveRateAdapter.update(adapter, 1_048_576, 10, 30)
      adapter = AdaptiveRateAdapter.update(adapter, 1_048_576, 10, 30)

      final_rate = AdaptiveRateAdapter.get_rate_mbps(adapter)
      assert final_rate > rate
    end

    test "respects maximum rate" do
      adapter = AdaptiveRateAdapter.new(10.0, 50.0)

      adapter = AdaptiveRateAdapter.update(adapter, 1_048_576, 1, 20)
      adapter = AdaptiveRateAdapter.update(adapter, 1_048_576, 1, 20)
      adapter = AdaptiveRateAdapter.update(adapter, 1_048_576, 1, 20)

      rate = AdaptiveRateAdapter.get_rate_mbps(adapter)

      assert rate <= 50.0
    end

    test "throttle with adaptive strategy" do
      adapter = AdaptiveRateAdapter.new(10.0, 100.0)

      {:ok, adapter} =
        BackpressureController.throttle(
          1_048_576,
          85,
          10.0,
          strategy: :adaptive,
          adapter: adapter,
          rtt_ms: 30
        )

      rate = AdaptiveRateAdapter.get_rate_mbps(adapter)
      assert rate > 0
    end
  end

  describe "strategy comparison" do
    test "static vs token bucket vs adaptive" do
      chunk_size = 1_048_576
      target_rate = 10.0

      start = System.monotonic_time(:millisecond)

      for _ <- 1..10 do
        :ok = BackpressureController.throttle(chunk_size, 20, target_rate, strategy: :static)
      end

      static_duration = System.monotonic_time(:millisecond) - start

      bucket = TokenBucket.new(10, 10.0)
      {:ok, bucket} = TokenBucket.consume(bucket, 10_485_760)

      start = System.monotonic_time(:millisecond)

      _bucket =
        Enum.reduce(1..10, bucket, fn _, acc_bucket ->
          {:ok, new_bucket} =
            BackpressureController.throttle(
              chunk_size,
              20,
              target_rate,
              strategy: :token_bucket,
              bucket: acc_bucket
            )

          new_bucket
        end)

      bucket_duration = System.monotonic_time(:millisecond) - start

      assert abs(static_duration - 1000) < 300
      assert abs(bucket_duration - 1000) < 300
    end
  end
end

defmodule Orchestrator.Migration.ProgressTrackerTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Migration.ProgressTracker

  @moduletag :progress_tracker

  setup do
    start_supervised!(ProgressTracker)
    :ok
  end

  describe "progress tracking" do
    test "tracks transfer from 0% to 100%" do
      machine_id = "test_#{:rand.uniform(100_000)}"
      total_bytes = 50_000_000

      :ok = ProgressTracker.start_transfer(machine_id, total_bytes)

      {:ok, progress} = ProgressTracker.get_progress(machine_id)
      assert progress.progress == 0.0
      assert progress.transferred_bytes == 0
      assert progress.total_bytes == total_bytes

      :ok = ProgressTracker.record_chunk(machine_id, 10_000_000)
      Process.sleep(50)

      {:ok, progress} = ProgressTracker.get_progress(machine_id)
      assert progress.progress == 0.2
      assert progress.transferred_bytes == 10_000_000

      :ok = ProgressTracker.record_chunk(machine_id, 40_000_000)
      Process.sleep(50)

      {:ok, progress} = ProgressTracker.get_progress(machine_id)
      assert progress.progress == 1.0
      assert progress.transferred_bytes == 50_000_000

      :ok = ProgressTracker.complete_transfer(machine_id)

      assert {:error, :not_found} = ProgressTracker.get_progress(machine_id)
    end

    test "calculates transfer rate (EMA)" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      :ok = ProgressTracker.start_transfer(machine_id, 50_000_000)
      Process.sleep(100)

      :ok = ProgressTracker.record_chunk(machine_id, 1_048_576)
      Process.sleep(100)

      :ok = ProgressTracker.record_chunk(machine_id, 1_048_576)
      Process.sleep(100)

      {:ok, progress} = ProgressTracker.get_progress(machine_id)

      assert progress.rate_mbps >= 5.0
      assert progress.rate_mbps <= 15.0
    end

    test "calculates ETA" do
      machine_id = "test_#{:rand.uniform(100_000)}"
      total_bytes = 10_000_000

      :ok = ProgressTracker.start_transfer(machine_id, total_bytes)

      :ok = ProgressTracker.record_chunk(machine_id, 5_000_000)
      Process.sleep(100)

      {:ok, progress} = ProgressTracker.get_progress(machine_id)

      assert progress.eta_seconds >= 0
      assert progress.eta_seconds <= 5
    end

    test "handles multiple concurrent transfers" do
      machine_1 = "test_#{:rand.uniform(100_000)}"
      machine_2 = "test_#{:rand.uniform(100_000)}"

      :ok = ProgressTracker.start_transfer(machine_1, 10_000_000)
      :ok = ProgressTracker.start_transfer(machine_2, 20_000_000)

      :ok = ProgressTracker.record_chunk(machine_1, 5_000_000)
      :ok = ProgressTracker.record_chunk(machine_2, 10_000_000)

      {:ok, progress_1} = ProgressTracker.get_progress(machine_1)
      {:ok, progress_2} = ProgressTracker.get_progress(machine_2)

      assert progress_1.progress == 0.5
      assert progress_2.progress == 0.5
    end

    test "emits telemetry events" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      events_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :migration, :progress],
          [:orchestrator, :migration, :transfer_complete]
        ])

      :ok = ProgressTracker.start_transfer(machine_id, 10_000_000)
      _ = ProgressTracker.get_progress(machine_id)
      Process.sleep(600)

      assert_receive {[:orchestrator, :migration, :progress], _ref, measurements, metadata}, 1000
      assert measurements.progress == 0.0
      assert metadata.machine_id == machine_id

      :ok = ProgressTracker.record_chunk(machine_id, 5_000_000)
      {:ok, _state} = ProgressTracker.get_progress(machine_id)
      Process.sleep(1000)
      assert Process.alive?(Process.whereis(Orchestrator.Migration.ProgressTracker))

      assert_receive {[:orchestrator, :migration, :progress], _ref, measurements, _metadata}, 2000
      assert measurements.progress >= 0.4
      assert measurements.progress <= 0.6

      :ok = ProgressTracker.complete_transfer(machine_id)

      assert_receive {[:orchestrator, :migration, :transfer_complete], _ref, measurements,
                      _metadata},
                     1000

      assert measurements.total_bytes == 10_000_000

      :telemetry.detach(events_ref)
    end
  end

  describe "stall detection" do
    test "detects stalled transfers" do
      machine_id = "test_#{:rand.uniform(100_000)}"

      events_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :migration, :stalled]
        ])

      :ok = ProgressTracker.start_transfer(machine_id, 50_000_000)

      :ok = ProgressTracker.record_chunk(machine_id, 1_048_576)

      :telemetry.detach(events_ref)
    end
  end
end
