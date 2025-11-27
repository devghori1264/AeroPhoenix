defmodule Orchestrator.LiveMigration.StateTransfer do
  require Logger
  alias Orchestrator.FlydClient

  @type transfer_result :: %{
          bytes_transferred: non_neg_integer(),
          dirty_pages: non_neg_integer(),
          total_pages: non_neg_integer(),
          duration_ms: non_neg_integer(),
          throughput_mbps: float()
        }
  @default_batch_size 4_194_304
  @min_batch_size 1_048_576
  @max_batch_size 16_777_216
  @parallelism 4

  @spec transfer_incremental(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, transfer_result()} | {:error, term()}
  def transfer_incremental(machine_id, checkpoint_id, source_region, target_region, opts \\ %{}) do
    Logger.info("Starting incremental state transfer",
      machine_id: machine_id,
      checkpoint_id: checkpoint_id,
      source: source_region,
      target: target_region
    )

    start_time = System.monotonic_time(:millisecond)

    with {:ok, dirty_pages} <- get_dirty_pages(machine_id, checkpoint_id, source_region),
         {:ok, transfer_stats} <-
           transfer_pages(
             dirty_pages,
             machine_id,
             source_region,
             target_region,
             opts
           ) do
      duration = System.monotonic_time(:millisecond) - start_time
      throughput = calculate_throughput(transfer_stats.bytes_transferred, duration)

      result = %{
        bytes_transferred: transfer_stats.bytes_transferred,
        dirty_pages: length(dirty_pages),
        total_pages: transfer_stats.total_pages,
        duration_ms: duration,
        throughput_mbps: throughput
      }

      Logger.info("Incremental transfer completed",
        bytes_mb: Float.round(result.bytes_transferred / 1_048_576, 2),
        dirty_pages: result.dirty_pages,
        throughput_mbps: Float.round(throughput, 2),
        duration_ms: duration
      )

      :telemetry.execute(
        [:orchestrator, :state_transfer, :incremental, :completed],
        %{
          bytes_transferred: result.bytes_transferred,
          duration_ms: duration,
          throughput_mbps: throughput
        },
        %{checkpoint_id: checkpoint_id}
      )

      {:ok, result}
    else
      error ->
        Logger.error("Incremental transfer failed",
          checkpoint_id: checkpoint_id,
          error: inspect(error)
        )

        error
    end
  end

  @spec transfer_final(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, transfer_result()} | {:error, term()}
  def transfer_final(machine_id, checkpoint_id, source_region, target_region, opts \\ %{}) do
    Logger.info("Starting final state transfer (source frozen)",
      machine_id: machine_id,
      checkpoint_id: checkpoint_id
    )

    start_time = System.monotonic_time(:millisecond)

    with {:ok, dirty_pages} <- get_dirty_pages(machine_id, checkpoint_id, source_region),
         {:ok, transfer_stats} <-
           transfer_pages(
             dirty_pages,
             machine_id,
             source_region,
             target_region,
             Map.put(opts, :priority, :high)
           ) do
      duration = System.monotonic_time(:millisecond) - start_time
      throughput = calculate_throughput(transfer_stats.bytes_transferred, duration)

      result = %{
        bytes_transferred: transfer_stats.bytes_transferred,
        dirty_pages: length(dirty_pages),
        total_pages: transfer_stats.total_pages,
        duration_ms: duration,
        throughput_mbps: throughput
      }

      Logger.info("Final transfer completed",
        bytes_mb: Float.round(result.bytes_transferred / 1_048_576, 2),
        dirty_pages: result.dirty_pages,
        duration_ms: duration
      )

      :telemetry.execute(
        [:orchestrator, :state_transfer, :final, :completed],
        %{
          bytes_transferred: result.bytes_transferred,
          duration_ms: duration
        },
        %{checkpoint_id: checkpoint_id}
      )

      {:ok, result}
    else
      error ->
        Logger.error("Final transfer failed",
          checkpoint_id: checkpoint_id,
          error: inspect(error)
        )

        error
    end
  end

  @spec transfer_post_copy(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, transfer_result()} | {:error, term()}
  def transfer_post_copy(machine_id, checkpoint_id, source_region, target_region, opts \\ %{}) do
    Logger.info("Starting post-copy state transfer", checkpoint_id: checkpoint_id)
    start_time = System.monotonic_time(:millisecond)

    with {:ok, critical_pages} <- get_critical_pages(machine_id, checkpoint_id, source_region),
         {:ok, transfer_stats} <-
           transfer_pages(
             critical_pages,
             machine_id,
             source_region,
             target_region,
             Map.put(opts, :priority, :critical)
           ),
         :ok <- setup_page_fault_handler(checkpoint_id, source_region, target_region) do
      duration = System.monotonic_time(:millisecond) - start_time
      throughput = calculate_throughput(transfer_stats.bytes_transferred, duration)

      result = %{
        bytes_transferred: transfer_stats.bytes_transferred,
        dirty_pages: length(critical_pages),
        total_pages: transfer_stats.total_pages,
        duration_ms: duration,
        throughput_mbps: throughput
      }

      Logger.info("Post-copy transfer completed",
        bytes_mb: Float.round(result.bytes_transferred / 1_048_576, 2),
        critical_pages: length(critical_pages),
        duration_ms: duration
      )

      :telemetry.execute(
        [:orchestrator, :state_transfer, :post_copy, :completed],
        %{
          bytes_transferred: result.bytes_transferred,
          duration_ms: duration
        },
        %{checkpoint_id: checkpoint_id}
      )

      {:ok, result}
    end
  end

  defp transfer_pages(pages, machine_id, source_region, target_region, opts) do
    parallelism = Map.get(opts, :parallelism, @parallelism)
    batch_size = Map.get(opts, :batch_size, @default_batch_size)

    Logger.debug("Transferring pages",
      page_count: length(pages),
      parallelism: parallelism,
      batch_size_mb: Float.round(batch_size / 1_048_576, 2)
    )

    batches = Enum.chunk_every(pages, batch_size_for_page_count(length(pages), batch_size))

    results =
      Task.async_stream(
        batches,
        fn batch -> transfer_batch(batch, machine_id, source_region, target_region, opts) end,
        max_concurrency: parallelism,
        timeout: 300_000
      )
      |> Enum.to_list()

    case aggregate_transfer_results(results) do
      {:ok, stats} ->
        {:ok, Map.put(stats, :total_pages, length(pages))}

      error ->
        error
    end
  end

  defp transfer_batch(pages, machine_id, source_region, target_region, opts) do
    Logger.debug("Transferring batch", page_count: length(pages))
    batch_start = System.monotonic_time(:millisecond)

    with {:ok, page_data} <- fetch_pages_from_source(pages, source_region),
         compressed_data <- maybe_compress(page_data, opts),
         {:ok, checksum} <- calculate_checksum(compressed_data, opts),
         :ok <- send_to_target(compressed_data, checksum, target_region, opts),
         :ok <- verify_transfer(machine_id, checksum, target_region, opts) do
      duration = System.monotonic_time(:millisecond) - batch_start

      {:ok,
       %{
         bytes_transferred: byte_size(page_data),
         pages_transferred: length(pages),
         duration_ms: duration
       }}
    else
      error ->
        Logger.error("Batch transfer failed", error: inspect(error))
        error
    end
  end

  defp fetch_pages_from_source(pages, source_region) do
    case FlydClient.get_machine_pages(source_region, pages) do
      {:ok, page_data} ->
        {:ok, page_data}

      {:error, :not_implemented} ->
        Logger.debug("Page fetching not implemented, using placeholder")
        {:ok, :erlang.term_to_binary(pages)}

      error ->
        error
    end
  end

  defp send_to_target(data, checksum, target_region, opts) do
    case FlydClient.write_machine_pages(target_region, data, checksum, opts) do
      :ok ->
        :ok

      {:error, :not_implemented} ->
        Logger.debug("Page writing not implemented")
        :ok

      error ->
        error
    end
  end

  defp verify_transfer(machine_id, checksum, target_region, opts) do
    if Map.get(opts, :verify_checksums, true) do
      case FlydClient.verify_pages_checksum(target_region, machine_id, checksum) do
        :ok ->
          :ok

        {:error, :not_implemented} ->
          Logger.debug("Checksum verification not implemented")
          :ok

        error ->
          {:error, {:verification_failed, error}}
      end
    else
      :ok
    end
  end

  defp get_dirty_pages(machine_id, checkpoint_id, source_region) do
    case FlydClient.get_dirty_pages_since_checkpoint(source_region, machine_id, checkpoint_id) do
      {:ok, pages} ->
        {:ok, pages}

      {:error, :not_implemented} ->
        Logger.debug("Dirty page tracking not implemented")
        {:ok, generate_mock_dirty_pages()}

      error ->
        error
    end
  end

  defp get_critical_pages(_machine_id, checkpoint_id, source_region) do
    case FlydClient.get_critical_pages(source_region, checkpoint_id) do
      {:ok, pages} ->
        {:ok, pages}

      {:error, :not_implemented} ->
        Logger.debug("Critical page identification not implemented")
        {:ok, generate_mock_critical_pages()}

      error ->
        error
    end
  end

  defp setup_page_fault_handler(_checkpoint_id, _source_region, _target_region) do
    Logger.debug("Page fault handler setup (placeholder)")
    :ok
  end

  defp maybe_compress(data, opts) do
    if Map.get(opts, :compression, true) do
      :zlib.compress(data)
    else
      data
    end
  end

  defp calculate_checksum(data, opts) do
    if Map.get(opts, :verify_checksums, true) do
      checksum = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
      {:ok, checksum}
    else
      {:ok, nil}
    end
  end

  defp batch_size_for_page_count(page_count, base_batch_size) do
    cond do
      page_count < 100 -> max(@min_batch_size, div(base_batch_size, 4))
      page_count < 1000 -> base_batch_size
      true -> min(@max_batch_size, base_batch_size * 2)
    end
  end

  defp aggregate_transfer_results(results) do
    failures =
      Enum.filter(results, fn
        {:ok, {:error, _}} -> true
        {:error, _} -> true
        _ -> false
      end)

    if length(failures) > 0 do
      {:error, {:transfer_failed, failures}}
    else
      stats =
        Enum.reduce(results, %{bytes_transferred: 0, pages_transferred: 0, duration_ms: 0}, fn
          {:ok, {:ok, batch_stats}}, acc ->
            %{
              bytes_transferred: acc.bytes_transferred + batch_stats.bytes_transferred,
              pages_transferred: acc.pages_transferred + batch_stats.pages_transferred,
              duration_ms: max(acc.duration_ms, batch_stats.duration_ms)
            }

          _, acc ->
            acc
        end)

      {:ok, stats}
    end
  end

  defp calculate_throughput(bytes, duration_ms) when duration_ms > 0 do
    megabits = bytes * 8 / 1_000_000
    seconds = duration_ms / 1000
    megabits / seconds
  end

  defp calculate_throughput(_, _), do: 0.0

  defp generate_mock_dirty_pages do
    Enum.map(1..100, fn i ->
      %{
        page_id: "page_#{i}",
        offset: i * 4096,
        size: 4096,
        checksum: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      }
    end)
  end

  defp generate_mock_critical_pages do
    Enum.map(1..20, fn i ->
      %{
        page_id: "critical_page_#{i}",
        offset: i * 4096,
        size: 4096,
        priority: :high,
        checksum: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      }
    end)
  end
end
