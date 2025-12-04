defmodule Orchestrator.LiveMigration.Checkpointer do
  require Logger
  @flyd_client Application.compile_env(:orchestrator, :flyd_client, Orchestrator.FlydClient)
  @type checkpoint_id :: String.t()
  @type checkpoint_type :: :full | :incremental | :differential
  @type checkpoint_metadata :: %{
          checkpoint_id: checkpoint_id(),
          machine_id: String.t(),
          type: checkpoint_type(),
          size_bytes: non_neg_integer(),
          compressed_size_bytes: non_neg_integer(),
          checksum: String.t(),
          created_at: DateTime.t(),
          parent_checkpoint_id: checkpoint_id() | nil
        }
  @default_compression_level 3
  @checkpoint_ttl_seconds 3600
  @spec create_checkpoint(String.t(), String.t(), map()) ::
          {:ok, checkpoint_id(), checkpoint_metadata()} | {:error, term()}
  def create_checkpoint(machine_id, region, opts \\ %{}) do
    opts =
      cond do
        is_map(opts) -> opts
        is_list(opts) -> Map.new(opts)
        is_atom(opts) -> %{type: opts}
        true -> %{}
      end

    checkpoint_id = generate_checkpoint_id()
    checkpoint_type = Map.get(opts, :type, :full)

    Logger.info("Creating checkpoint",
      checkpoint_id: checkpoint_id,
      machine_id: machine_id,
      type: checkpoint_type
    )

    start_time = System.monotonic_time(:millisecond)

    with {:ok, memory_snapshot} <- capture_memory_state(machine_id, region, opts),
         {:ok, fs_snapshot} <- capture_filesystem_state(machine_id, region, opts),
         {:ok, network_snapshot} <- capture_network_state(machine_id, region, opts),
         {:ok, app_snapshot} <- capture_application_state(machine_id, region, opts) do
      checkpoint_data = %{
        memory: memory_snapshot,
        filesystem: fs_snapshot,
        network: network_snapshot,
        application: app_snapshot
      }

      {final_data, compressed_size} =
        if Map.get(opts, :compression, true) do
          compress_checkpoint(
            checkpoint_data,
            Map.get(opts, :compression_level, @default_compression_level)
          )
        else
          serialized = :erlang.term_to_binary(checkpoint_data)
          {serialized, byte_size(serialized)}
        end

      checksum = :crypto.hash(:sha256, final_data) |> Base.encode16(case: :lower)
      duration = System.monotonic_time(:millisecond) - start_time

      metadata = %{
        checkpoint_id: checkpoint_id,
        machine_id: machine_id,
        type: checkpoint_type,
        size_bytes: byte_size(:erlang.term_to_binary(checkpoint_data)),
        compressed_size_bytes: compressed_size,
        checksum: checksum,
        created_at: DateTime.utc_now(),
        parent_checkpoint_id: Map.get(opts, :parent_checkpoint_id) || Map.get(opts, :base_checkpoint)
      }

      case store_checkpoint(checkpoint_id, final_data, metadata) do
        :ok ->
          Logger.info("Checkpoint created successfully",
            checkpoint_id: checkpoint_id,
            size_mb: Float.round(metadata.size_bytes / 1_048_576, 2),
            compressed_mb: Float.round(compressed_size / 1_048_576, 2),
            compression_ratio: Float.round(metadata.size_bytes / max(compressed_size, 1), 2),
            duration_ms: duration
          )

          :telemetry.execute(
            [:orchestrator, :checkpoint, :created],
            %{
              duration_ms: duration,
              size_bytes: metadata.size_bytes,
              compressed_size_bytes: compressed_size
            },
            %{checkpoint_id: checkpoint_id, type: checkpoint_type}
          )

          schedule_checkpoint_cleanup(checkpoint_id)
          {:ok, checkpoint_id, metadata}
      end
    else
      {:error, reason} = error ->
        Logger.error("Checkpoint creation failed",
          checkpoint_id: checkpoint_id,
          reason: reason
        )

        :telemetry.execute(
          [:orchestrator, :checkpoint, :failed],
          %{},
          %{checkpoint_id: checkpoint_id, reason: reason}
        )

        error
    end
  end

  @spec restore_checkpoint(checkpoint_id(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def restore_checkpoint(checkpoint_id, machine_id, target_region) do
    Logger.info("Restoring checkpoint",
      checkpoint_id: checkpoint_id,
      machine_id: machine_id,
      target_region: target_region
    )

    start_time = System.monotonic_time(:millisecond)

    with {:ok, checkpoint_data} <- load_checkpoint(checkpoint_id),
         {:ok, decompressed} <- decompress_checkpoint(checkpoint_data),
         {:ok, _} <- restore_filesystem_state(decompressed.filesystem, machine_id, target_region),
         {:ok, _} <- restore_memory_state(decompressed.memory, machine_id, target_region),
         {:ok, _} <- restore_network_state(decompressed.network, machine_id, target_region),
         {:ok, _} <-
           restore_application_state(decompressed.application, machine_id, target_region) do
      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info("Checkpoint restored successfully",
        checkpoint_id: checkpoint_id,
        duration_ms: duration
      )

      :telemetry.execute(
        [:orchestrator, :checkpoint, :restored],
        %{duration_ms: duration},
        %{checkpoint_id: checkpoint_id}
      )

      {:ok, %{restored: true, duration_ms: duration}}
    else
      error ->
        Logger.error("Checkpoint restore failed",
          checkpoint_id: checkpoint_id,
          error: inspect(error)
        )

        error
    end
  end

  @spec delete_checkpoint(checkpoint_id()) :: :ok | {:error, term()}
  def delete_checkpoint(checkpoint_id) do
    Logger.info("Deleting checkpoint", checkpoint_id: checkpoint_id)

    case remove_from_storage(checkpoint_id) do
      :ok ->
        :telemetry.execute(
          [:orchestrator, :checkpoint, :deleted],
          %{},
          %{checkpoint_id: checkpoint_id}
        )

        :ok

      error ->
        Logger.warning("Failed to delete checkpoint",
          checkpoint_id: checkpoint_id,
          error: inspect(error)
        )

        error
    end
  end

  @spec get_checkpoint_info(checkpoint_id()) ::
          {:ok, checkpoint_metadata()} | {:error, :not_found}
  def get_checkpoint_info(checkpoint_id) do
    case :ets.lookup(:checkpoints, checkpoint_id) do
      [{^checkpoint_id, metadata, _data}] ->
        {:ok, metadata}

      [] ->
        {:error, :not_found}
    end
  end

  defp capture_memory_state(machine_id, region, _opts) do
    Logger.debug("Capturing memory state", machine_id: machine_id)

    case @flyd_client.get_machine_memory_dump(region, machine_id) do
      {:ok, memory_dump} ->
        {:ok,
         %{
           heap: memory_dump["heap"],
           stack: memory_dump["stack"],
           dirty_pages: memory_dump["dirty_pages"] || [],
           total_pages: memory_dump["total_pages"] || 0
         }}

      error ->
        error
    end
  end

  defp capture_filesystem_state(machine_id, region, _opts) do
    Logger.debug("Capturing filesystem state", machine_id: machine_id)

    case @flyd_client.create_fs_snapshot(region, machine_id) do
      {:ok, snapshot_id} ->
        {:ok,
         %{
           snapshot_id: snapshot_id,
           snapshot_type: :cow
         }}

      error ->
        error
    end
  end

  defp capture_network_state(machine_id, region, _opts) do
    Logger.debug("Capturing network state", machine_id: machine_id)

    case @flyd_client.get_machine_network_state(region, machine_id) do
      {:ok, network_state} ->
        {:ok,
         %{
           connections: network_state["connections"] || [],
           listening_ports: network_state["listening_ports"] || [],
           socket_buffers: network_state["socket_buffers"] || []
         }}

      error ->
        error
    end
  end

  defp capture_application_state(machine_id, region, _opts) do
    Logger.debug("Capturing application state", machine_id: machine_id)

    case @flyd_client.get_machine_app_state(region, machine_id) do
      {:ok, app_state} ->
        {:ok, app_state}

      error ->
        error
    end
  end

  defp restore_filesystem_state(fs_state, machine_id, target_region) do
    Logger.debug("Restoring filesystem state", machine_id: machine_id)

    if fs_state.snapshot_id do
      @flyd_client.restore_fs_snapshot(target_region, machine_id, fs_state.snapshot_id)
    else
      {:ok, :skipped}
    end
  end

  defp restore_memory_state(memory_state, machine_id, target_region) do
    Logger.debug("Restoring memory state", machine_id: machine_id)

    if memory_state.heap do
      @flyd_client.restore_machine_memory(target_region, machine_id, memory_state)
    else
      {:ok, :skipped}
    end
  end

  defp restore_network_state(network_state, machine_id, target_region) do
    Logger.debug("Restoring network state", machine_id: machine_id)
    @flyd_client.restore_machine_network_state(target_region, machine_id, network_state)
  end

  defp restore_application_state(app_state, machine_id, target_region) do
    Logger.debug("Restoring application state", machine_id: machine_id)
    @flyd_client.restore_machine_app_state(target_region, machine_id, app_state)
  end

  defp compress_checkpoint(data, level) do
    serialized = :erlang.term_to_binary(data)

    compressed =
      case level do
        l when l in 1..9 ->
          :zlib.compress(serialized)

        _ ->
          serialized
      end

    {compressed, byte_size(compressed)}
  end

  defp decompress_checkpoint(compressed_data) do
    try do
      decompressed = :zlib.uncompress(compressed_data)
      data = :erlang.binary_to_term(decompressed)
      {:ok, data}
    rescue
      _ ->
        try do
          data = :erlang.binary_to_term(compressed_data)
          {:ok, data}
        rescue
          e ->
            {:error, {:decompression_failed, e}}
        end
    end
  end

  defp store_checkpoint(checkpoint_id, data, metadata) do
    :ets.insert(:checkpoints, {checkpoint_id, metadata, data})
    Logger.debug("Checkpoint stored", checkpoint_id: checkpoint_id)
    :ok
  end

  defp load_checkpoint(checkpoint_id) do
    case :ets.lookup(:checkpoints, checkpoint_id) do
      [{^checkpoint_id, _metadata, data}] ->
        {:ok, data}

      [] ->
        {:error, :not_found}
    end
  end

  defp remove_from_storage(checkpoint_id) do
    :ets.delete(:checkpoints, checkpoint_id)
    :ok
  end

  defp schedule_checkpoint_cleanup(checkpoint_id) do
    Process.send_after(
      self(),
      {:cleanup_checkpoint, checkpoint_id},
      @checkpoint_ttl_seconds * 1000
    )
  end

  defp generate_checkpoint_id do
    "ckpt_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
