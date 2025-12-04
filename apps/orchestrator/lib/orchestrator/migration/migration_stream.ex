defmodule Orchestrator.Migration.MigrationStream do
  use GenServer
  require Logger

  def init(_), do: {:ok, %{}}

  alias Orchestrator.Migration.ProgressTracker

  @type machine_id :: String.t()
  @type region :: atom()
  @type transfer_opts :: keyword()

  @chunk_size_bytes 1_048_576
  @target_bandwidth_mbps 10
  @max_retries 10

  @spec stream_volume(machine_id(), transfer_opts()) :: {:ok, map()} | {:error, term()}
  def stream_volume(machine_id, opts \\ []) do
    source_region = Keyword.fetch!(opts, :source_region)
    dest_region = Keyword.fetch!(opts, :dest_region)

    chunk_size = Keyword.get(opts, :chunk_size, @chunk_size_bytes)
    bandwidth_limit = Keyword.get(opts, :bandwidth_limit_mbps, @target_bandwidth_mbps)
    enable_compression = Keyword.get(opts, :enable_compression, true)
    checkpoint_interval = Keyword.get(opts, :checkpoint_interval, 100)

    Logger.info("Starting volume streaming migration",
      machine_id: machine_id,
      source: source_region,
      dest: dest_region,
      chunk_size_mb: chunk_size / 1_048_576,
      bandwidth_limit_mbps: bandwidth_limit
    )

    volume_path = generate_volume_file(machine_id)
    total_size = File.stat!(volume_path).size
    total_chunks = div(total_size, chunk_size) + 1

    Logger.info("Volume file generated",
      machine_id: machine_id,
      size_mb: total_size / 1_048_576,
      total_chunks: total_chunks
    )

    ProgressTracker.start_transfer(machine_id, total_size)

    start_time = System.monotonic_time(:millisecond)

    result =
      File.stream!(volume_path, [], chunk_size)
      |> Stream.with_index()
      |> Stream.map(fn {chunk, index} ->
        chunk_start = System.monotonic_time(:millisecond)

        {data_to_send, original_size, compressed_size} =
          if enable_compression do
            compressed = compress_chunk(chunk)
            {compressed, byte_size(chunk), byte_size(compressed)}
          else
            {chunk, byte_size(chunk), byte_size(chunk)}
          end

        case send_chunk_with_retry(dest_region, data_to_send, index, machine_id) do
          :ok ->
            chunk_duration = System.monotonic_time(:millisecond) - chunk_start

            ProgressTracker.record_chunk(machine_id, original_size)

            :telemetry.execute(
              [:orchestrator, :migration, :chunk_transferred],
              %{
                bytes: original_size,
                compressed_bytes: compressed_size,
                duration_ms: chunk_duration,
                compression_ratio:
                  if(enable_compression, do: original_size / compressed_size, else: 1.0)
              },
              %{machine_id: machine_id, chunk_index: index}
            )

            apply_backpressure(original_size, bandwidth_limit, chunk_duration)

            if rem(index, checkpoint_interval) == 0 do
              save_checkpoint(machine_id, index, total_chunks)
            end

            {:ok, index}

          {:error, reason} ->
            {:error, {:chunk_failed, index: index, reason: reason}}
        end
      end)
      |> Enum.reduce_while({:ok, 0}, fn
        {:ok, _index}, {:ok, count} -> {:cont, {:ok, count + 1}}
        {:error, reason}, _acc -> {:halt, {:error, reason}}
      end)

    total_duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, chunks_transferred} ->
        stats = %{
          chunks_transferred: chunks_transferred,
          total_bytes: total_size,
          duration_ms: total_duration,
          throughput_mbps: total_size / 1_048_576 / (total_duration / 1000),
          avg_chunk_latency_ms: total_duration / chunks_transferred
        }

        Logger.info("Volume streaming completed",
          machine_id: machine_id,
          stats: stats
        )

        :telemetry.execute(
          [:orchestrator, :migration, :stream_completed],
          stats,
          %{machine_id: machine_id, source: source_region, dest: dest_region}
        )

        File.rm(volume_path)

        {:ok, stats}

      {:error, reason} ->
        Logger.error("Volume streaming failed",
          machine_id: machine_id,
          reason: reason
        )

        {:error, reason}
    end
  end

  defp generate_volume_file(machine_id) do
    path = "/tmp/volume_#{machine_id}_#{System.monotonic_time()}.bin"

    File.write!(path, generate_semi_compressible_data(50 * 1024 * 1024))

    path
  end

  defp generate_semi_compressible_data(total_bytes) do
    random_portion = div(total_bytes, 2)
    pattern_portion = total_bytes - random_portion

    random_data = :crypto.strong_rand_bytes(random_portion)

    pattern_block = "MACHINE_DATA_BLOCK_0123456789ABCDEF"

    pattern_data =
      Stream.cycle([pattern_block])
      |> Enum.take(div(pattern_portion, byte_size(pattern_block)) + 1)
      |> Enum.join()
      |> binary_part(0, pattern_portion)

    random_data <> pattern_data
  end

  defp compress_chunk(chunk) do
    compressed_size = div(byte_size(chunk), 2)
    binary_part(chunk, 0, compressed_size)
  end

  defp send_chunk_with_retry(dest_region, chunk, index, machine_id, attempt \\ 1) do
    case simulate_chunk_send(dest_region, chunk, index) do
      :ok ->
        :ok

      {:error, reason} when attempt < @max_retries ->
        delay_ms = min(100 * :math.pow(2, attempt - 1), 60_000)
        jitter = delay_ms * (0.75 + :rand.uniform() * 0.5)

        Logger.info("Chunk send failed, retrying",
          machine_id: machine_id,
          chunk: index,
          attempt: attempt,
          delay_ms: round(jitter),
          reason: reason
        )

        :telemetry.execute(
          [:orchestrator, :migration, :chunk_retry],
          %{attempt: attempt, delay_ms: round(jitter)},
          %{machine_id: machine_id, chunk_index: index}
        )

        Process.sleep(round(jitter))
        send_chunk_with_retry(dest_region, chunk, index, machine_id, attempt + 1)

      {:error, reason} ->
        Logger.error("Chunk send failed permanently",
          machine_id: machine_id,
          chunk: index,
          attempts: attempt,
          reason: reason
        )

        :telemetry.execute(
          [:orchestrator, :migration, :chunk_failed],
          %{retry_count: attempt},
          %{machine_id: machine_id, chunk_index: index, error: reason}
        )

        {:error, reason}
    end
  end

  defp simulate_chunk_send(_dest_region, _chunk, _index) do
    if :rand.uniform(1000) == 1 do
      {:error, :network_timeout}
    else
      :ok
    end
  end

  defp apply_backpressure(bytes_sent, bandwidth_limit_mbps, actual_duration_ms) do
    target_duration_ms = bytes_sent / (bandwidth_limit_mbps * 1_048_576) * 1000

    sleep_ms = max(0, target_duration_ms - actual_duration_ms)

    if sleep_ms > 0 do
      Process.sleep(round(sleep_ms))
    end
  end

  defp save_checkpoint(machine_id, chunk_index, total_chunks) do
    progress = chunk_index / total_chunks

    Logger.debug("Migration checkpoint",
      machine_id: machine_id,
      chunk: chunk_index,
      progress: Float.round(progress * 100, 2)
    )

    :ok
  end
end
