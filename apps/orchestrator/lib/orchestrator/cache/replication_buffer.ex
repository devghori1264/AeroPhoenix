defmodule Orchestrator.Cache.ReplicationBuffer do
  use GenServer
  require Logger

  alias Orchestrator.Replication.CRDT.VectorClock

  @type machine_id :: String.t()
  @type update :: %{
          machine_id: machine_id(),
          data: term(),
          hlc: pos_integer(),
          vector_clock: VectorClock.t()
        }

  @type state :: %{
          pending: %{machine_id() => update()},
          debounce_ms: pos_integer(),
          flush_timer_ref: reference() | nil,
          stats: %{
            batches_flushed: non_neg_integer(),
            total_updates: non_neg_integer(),
            retries: non_neg_integer(),
            dlq_size: non_neg_integer()
          }
        }

  @default_debounce_ms 100
  @max_batch_size 1_000
  @max_batch_bytes 1_048_576
  @max_retry_attempts 10

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec enqueue(GenServer.server(), machine_id(), term()) :: :ok
  def enqueue(server, machine_id, data) do
    GenServer.cast(server, {:enqueue, machine_id, data})
  end

  @spec flush(GenServer.server()) :: :ok
  def flush(server) do
    GenServer.call(server, :flush)
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)

    if :ets.info(:replication_dlq) == :undefined do
      :ets.new(:replication_dlq, [:set, :public, :named_table])
    end

    state = %{
      pending: %{},
      debounce_ms: debounce_ms,
      flush_timer_ref: nil,
      stats: %{
        batches_flushed: 0,
        total_updates: 0,
        retries: 0,
        dlq_size: 0
      }
    }

    Logger.info("ReplicationBuffer started", debounce_ms: debounce_ms)

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, machine_id, data}, state) do
    hlc = Map.get(data, :hlc, System.monotonic_time(:millisecond))
    vector_clock = Map.get(data, :vector_clock, VectorClock.new())

    update = %{
      machine_id: machine_id,
      data: data,
      hlc: hlc,
      vector_clock: vector_clock
    }

    new_pending =
      case Map.get(state.pending, machine_id) do
        nil ->
          Map.put(state.pending, machine_id, update)

        existing_update ->
          if hlc > existing_update.hlc do
            Map.put(state.pending, machine_id, update)
          else
            Logger.debug("Discarding stale update",
              machine_id: machine_id,
              new_hlc: hlc,
              existing_hlc: existing_update.hlc
            )

            state.pending
          end
      end

    should_flush =
      map_size(new_pending) >= @max_batch_size or
        estimate_batch_size_bytes(new_pending) >= @max_batch_bytes

    if should_flush do
      new_state = flush_batch(%{state | pending: new_pending})
      {:noreply, new_state}
    else
      new_timer_ref =
        if state.flush_timer_ref do
          Process.cancel_timer(state.flush_timer_ref)
          Process.send_after(self(), :flush_batch, state.debounce_ms)
        else
          Process.send_after(self(), :flush_batch, state.debounce_ms)
        end

      {:noreply, %{state | pending: new_pending, flush_timer_ref: new_timer_ref}}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    new_state = flush_batch(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    avg_batch_size =
      if state.stats.batches_flushed > 0 do
        state.stats.total_updates / state.stats.batches_flushed
      else
        0.0
      end

    retry_rate_pct =
      if state.stats.batches_flushed > 0 do
        state.stats.retries / state.stats.batches_flushed * 100
      else
        0.0
      end

    stats =
      Map.merge(state.stats, %{
        pending_count: map_size(state.pending),
        avg_batch_size: Float.round(avg_batch_size, 1),
        retry_rate_pct: Float.round(retry_rate_pct, 2)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush_batch, state) do
    new_state = flush_batch(state)
    {:noreply, new_state}
  end

  defp flush_batch(state) do
    batch_size = map_size(state.pending)

    if batch_size == 0 do
      %{state | flush_timer_ref: nil}
    else
      Logger.debug("Flushing replication batch", size: batch_size)

      updates = Map.values(state.pending)

      case write_to_postgres_with_retry(updates) do
        {:ok, _} ->
          :telemetry.execute(
            [:orchestrator, :replication, :batch_flushed],
            %{size: batch_size},
            %{}
          )

          new_stats =
            state.stats
            |> Map.update!(:batches_flushed, &(&1 + 1))
            |> Map.update!(:total_updates, &(&1 + batch_size))

          %{state | pending: %{}, flush_timer_ref: nil, stats: new_stats}

        {:error, reason} ->
          Logger.error("Batch replication failed permanently", reason: reason, size: batch_size)

          Enum.each(updates, fn update ->
            :ets.insert(:replication_dlq, {
              System.monotonic_time(:millisecond),
              update.machine_id,
              update,
              reason
            })
          end)

          dlq_size = :ets.info(:replication_dlq, :size)

          new_stats =
            state.stats
            |> Map.put(:dlq_size, dlq_size)

          :telemetry.execute(
            [:orchestrator, :replication, :dlq],
            %{size: batch_size},
            %{reason: reason}
          )

          %{state | pending: %{}, flush_timer_ref: nil, stats: new_stats}
      end
    end
  end

  defp write_to_postgres_with_retry(updates, attempt \\ 1) do
    case write_to_postgres(updates) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when attempt < @max_retry_attempts ->
        delay_ms = min(:math.pow(2, attempt) * 100, 30_000) |> round()

        Logger.warning("PostgreSQL write failed, retrying",
          attempt: attempt,
          max_attempts: @max_retry_attempts,
          delay_ms: delay_ms,
          reason: reason
        )

        :telemetry.execute(
          [:orchestrator, :replication, :retry],
          %{attempt: attempt},
          %{reason: reason}
        )

        Process.sleep(delay_ms)
        write_to_postgres_with_retry(updates, attempt + 1)

      {:error, reason} ->
        Logger.error("Max retry attempts exceeded", reason: reason)
        {:error, :max_retries_exceeded}
    end
  end

  defp write_to_postgres(updates) do
    if :rand.uniform(100) <= 5 do
      {:error, :simulated_network_error}
    else
      :ok
      {:ok, length(updates)}
    end
  end

  defp estimate_batch_size_bytes(pending_map) do
    Map.values(pending_map)
    |> Enum.map(&:erlang.external_size/1)
    |> Enum.sum()
  end
end
