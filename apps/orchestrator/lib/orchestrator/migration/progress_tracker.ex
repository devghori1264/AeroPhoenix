defmodule Orchestrator.Migration.ProgressTracker do
  use GenServer
  require Logger

  @type machine_id :: String.t()
  @type transfer_state :: %{
          machine_id: machine_id(),
          total_bytes: non_neg_integer(),
          transferred_bytes: non_neg_integer(),
          start_time_ms: integer(),
          last_update_ms: integer(),
          last_emit_ms: integer(),
          bytes_since_last_emit: non_neg_integer(),
          rate_history: list(float()),
          ema_rate_mbps: float(),
          chunks_transferred: non_neg_integer()
        }

  @ema_alpha 0.3
  @rate_history_window 10
  @stall_threshold_ms 30_000
  @min_emit_interval_ms 500

  @spec start_transfer(machine_id(), non_neg_integer()) :: :ok
  def start_transfer(machine_id, total_bytes) do
    GenServer.cast(__MODULE__, {:start_transfer, machine_id, total_bytes})
  end

  @spec record_chunk(machine_id(), non_neg_integer()) :: :ok
  def record_chunk(machine_id, chunk_bytes) do
    GenServer.cast(__MODULE__, {:record_chunk, machine_id, chunk_bytes})
  end

  @spec get_progress(machine_id()) :: {:ok, map()} | {:error, :not_found}
  def get_progress(machine_id) do
    GenServer.call(__MODULE__, {:get_progress, machine_id})
  end

  @spec complete_transfer(machine_id()) :: :ok
  def complete_transfer(machine_id) do
    GenServer.cast(__MODULE__, {:complete_transfer, machine_id})
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:start_transfer, machine_id, total_bytes}, state) do
    now = System.monotonic_time(:millisecond)

    transfer_state = %{
      machine_id: machine_id,
      total_bytes: total_bytes,
      transferred_bytes: 0,
      start_time_ms: now,
      last_update_ms: now,
      last_emit_ms: now,
      bytes_since_last_emit: 0,
      rate_history: [],
      ema_rate_mbps: 0.0,
      chunks_transferred: 0
    }

    Logger.info("Progress tracking started",
      machine_id: machine_id,
      total_bytes: total_bytes,
      total_mb: Float.round(total_bytes / 1_048_576, 2)
    )

    emit_progress_event(transfer_state)

    {:noreply, Map.put(state, machine_id, transfer_state)}
  end

  @impl true
  def handle_cast({:record_chunk, machine_id, chunk_bytes}, state) do
    case Map.get(state, machine_id) do
      nil ->
        Logger.warning("Chunk recorded for unknown transfer", machine_id: machine_id)
        {:noreply, state}

      transfer_state ->
        now = System.monotonic_time(:millisecond)

        duration_since_last = now - transfer_state.last_update_ms
        instant_rate_mbps = chunk_bytes / 1_048_576 / (duration_since_last / 1000)

        ema_rate =
          if transfer_state.ema_rate_mbps == 0.0 do
            instant_rate_mbps
          else
            @ema_alpha * instant_rate_mbps + (1 - @ema_alpha) * transfer_state.ema_rate_mbps
          end

        rate_history =
          [instant_rate_mbps | transfer_state.rate_history]
          |> Enum.take(@rate_history_window)

        updated_state = %{
          transfer_state
          | transferred_bytes: transfer_state.transferred_bytes + chunk_bytes,
            last_update_ms: now,
            bytes_since_last_emit: transfer_state.bytes_since_last_emit + chunk_bytes,
            rate_history: rate_history,
            ema_rate_mbps: ema_rate,
            chunks_transferred: transfer_state.chunks_transferred + 1
        }

        updated_state =
          if should_emit_progress?(updated_state, now) do
            emit_progress_event(updated_state)
            %{updated_state | last_emit_ms: now, bytes_since_last_emit: 0}
          else
            updated_state
          end

        check_stall(updated_state, now)

        {:noreply, Map.put(state, machine_id, updated_state)}
    end
  end

  @impl true
  def handle_cast({:complete_transfer, machine_id}, state) do
    case Map.get(state, machine_id) do
      nil ->
        {:noreply, state}

      transfer_state ->
        now = System.monotonic_time(:millisecond)
        total_duration_ms = now - transfer_state.start_time_ms

        avg_rate_mbps = transfer_state.total_bytes / 1_048_576 / (total_duration_ms / 1000)

        Logger.info("Transfer completed",
          machine_id: machine_id,
          total_bytes: transfer_state.total_bytes,
          duration_seconds: Float.round(total_duration_ms / 1000, 2),
          avg_rate_mbps: Float.round(avg_rate_mbps, 2),
          chunks: transfer_state.chunks_transferred
        )

        :telemetry.execute(
          [:orchestrator, :migration, :transfer_complete],
          %{
            total_bytes: transfer_state.total_bytes,
            duration_ms: total_duration_ms,
            avg_rate_mbps: avg_rate_mbps,
            chunks_transferred: transfer_state.chunks_transferred
          },
          %{machine_id: machine_id}
        )

        {:noreply, Map.delete(state, machine_id)}
    end
  end

  @impl true
  def handle_call({:get_progress, machine_id}, _from, state) do
    case Map.get(state, machine_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      transfer_state ->
        progress = calculate_progress(transfer_state)
        {:reply, {:ok, progress}, state}
    end
  end

  defp should_emit_progress?(transfer_state, now) do
    elapsed_since_last_emit = now - transfer_state.last_emit_ms

    cond do
      elapsed_since_last_emit < @min_emit_interval_ms ->
        false

      transfer_state.ema_rate_mbps > 50 ->
        transfer_state.bytes_since_last_emit > 5_242_880

      transfer_state.ema_rate_mbps > 10 ->
        transfer_state.bytes_since_last_emit > 1_048_576

      true ->
        elapsed_since_last_emit > @min_emit_interval_ms
    end
  end

  defp emit_progress_event(transfer_state) do
    progress = calculate_progress(transfer_state)

    Logger.debug("Progress update",
      machine_id: transfer_state.machine_id,
      progress: Float.round(progress.progress * 100, 2),
      rate_mbps: Float.round(progress.rate_mbps, 2),
      eta_seconds: progress.eta_seconds
    )

    :telemetry.execute(
      [:orchestrator, :migration, :progress],
      %{
        progress: progress.progress,
        transferred_bytes: progress.transferred_bytes,
        total_bytes: progress.total_bytes,
        rate_mbps: progress.rate_mbps,
        eta_seconds: progress.eta_seconds
      },
      %{machine_id: transfer_state.machine_id}
    )
  end

  defp calculate_progress(transfer_state) do
    now = System.monotonic_time(:millisecond)
    elapsed_seconds = (now - transfer_state.start_time_ms) / 1000

    progress = transfer_state.transferred_bytes / transfer_state.total_bytes
    remaining_bytes = transfer_state.total_bytes - transfer_state.transferred_bytes

    eta_seconds =
      if transfer_state.ema_rate_mbps > 0 do
        remaining_bytes / (transfer_state.ema_rate_mbps * 1_048_576)
      else
        :infinity
      end

    %{
      progress: progress,
      transferred_bytes: transfer_state.transferred_bytes,
      total_bytes: transfer_state.total_bytes,
      rate_mbps: transfer_state.ema_rate_mbps,
      eta_seconds: if(is_number(eta_seconds), do: round(eta_seconds), else: nil),
      elapsed_seconds: round(elapsed_seconds),
      chunks_transferred: transfer_state.chunks_transferred
    }
  end

  defp check_stall(transfer_state, now) do
    time_since_last_update = now - transfer_state.last_update_ms

    if time_since_last_update > @stall_threshold_ms do
      Logger.warning("Transfer stalled",
        machine_id: transfer_state.machine_id,
        stalled_for_seconds: round(time_since_last_update / 1000),
        progress:
          Float.round(transfer_state.transferred_bytes / transfer_state.total_bytes * 100, 2)
      )

      :telemetry.execute(
        [:orchestrator, :migration, :stalled],
        %{stalled_duration_ms: time_since_last_update},
        %{machine_id: transfer_state.machine_id}
      )
    end
  end
end
