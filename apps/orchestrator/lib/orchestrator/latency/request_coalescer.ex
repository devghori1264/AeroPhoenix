defmodule Orchestrator.Latency.RequestCoalescer do
  use GenServer
  require Logger

  @type request_id :: term()
  @type request :: term()
  @type result :: term()
  @type waiter :: {pid(), reference()}

  @type batch :: %{
          requests: %{request_id() => [waiter()]},
          started_at: integer(),
          size_bytes: non_neg_integer()
        }

  @type state :: %{
          operation_type: atom(),
          pending_batch: batch() | nil,
          batch_window_ms: pos_integer(),
          max_batch_size: pos_integer(),
          max_batch_bytes: pos_integer(),
          flush_timer_ref: reference() | nil,
          executor_fn: (map() -> map()),
          metrics: map()
        }

  @default_batch_window_ms 10
  @default_max_batch_size 100
  @default_max_batch_bytes 512_000
  @min_batch_window_ms 1

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    operation_type = Keyword.fetch!(opts, :operation_type)
    name = {:via, Registry, {Orchestrator.Registry, {:coalescer, operation_type}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec execute(GenServer.server(), keyword()) :: {:ok, result()} | {:error, term()}
  def execute(server, opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    request = Keyword.fetch!(opts, :request)
    timeout = Keyword.get(opts, :timeout, 5_000)

    waiter_ref = make_ref()

    GenServer.cast(server, {:add_to_batch, request_id, request, {self(), waiter_ref}})

    receive do
      {:batch_result, ^waiter_ref, result} ->
        {:ok, result}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    operation_type = Keyword.fetch!(opts, :operation_type)
    executor_fn = Keyword.fetch!(opts, :executor_fn)

    requested_window_ms = Keyword.get(opts, :batch_window_ms, @default_batch_window_ms)
    batch_window_ms = max(requested_window_ms, @min_batch_window_ms)

    state = %{
      operation_type: operation_type,
      pending_batch: nil,
      batch_window_ms: batch_window_ms,
      max_batch_size: Keyword.get(opts, :max_batch_size, @default_max_batch_size),
      max_batch_bytes: Keyword.get(opts, :max_batch_bytes, @default_max_batch_bytes),
      flush_timer_ref: nil,
      executor_fn: executor_fn,
      metrics: initialize_metrics()
    }

    Logger.info("RequestCoalescer started",
      operation_type: operation_type,
      batch_window_ms: state.batch_window_ms
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:add_to_batch, request_id, request, waiter}, state) do
    batch =
      case state.pending_batch do
        nil ->
          %{
            requests: %{},
            started_at: System.monotonic_time(:millisecond),
            size_bytes: 0
          }

        existing_batch ->
          existing_batch
      end

    existing_waiters = Map.get(batch.requests, request_id, [])
    updated_requests = Map.put(batch.requests, request_id, [waiter | existing_waiters])

    request_size_bytes = estimate_request_size(request)
    updated_size_bytes = batch.size_bytes + request_size_bytes

    updated_batch = %{
      batch
      | requests: updated_requests,
        size_bytes: updated_size_bytes
    }

    should_flush =
      map_size(updated_batch.requests) >= state.max_batch_size or
        updated_batch.size_bytes >= state.max_batch_bytes

    new_state =
      if should_flush do
        flush_batch(updated_batch, state)
      else
        timer_ref =
          if state.flush_timer_ref == nil do
            Process.send_after(self(), :flush_batch, state.batch_window_ms)
          else
            state.flush_timer_ref
          end

        %{state | pending_batch: updated_batch, flush_timer_ref: timer_ref}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = compile_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush_batch, state) do
    new_state =
      case state.pending_batch do
        nil ->
          %{state | flush_timer_ref: nil}

        batch ->
          flush_batch(batch, state)
      end

    {:noreply, new_state}
  end

  defp flush_batch(batch, state) do
    batch_size = map_size(batch.requests)

    if batch_size == 0 do
      %{state | pending_batch: nil, flush_timer_ref: nil}
    else
      unique_requests = Map.keys(batch.requests)
      unique_count = length(unique_requests)
      total_waiters = Enum.sum(Enum.map(batch.requests, fn {_id, waiters} -> length(waiters) end))

      Logger.debug("Flushing batch",
        operation_type: state.operation_type,
        unique_requests: unique_count,
        total_waiters: total_waiters,
        dedup_savings: total_waiters - unique_count
      )

      start_time = System.monotonic_time(:millisecond)

      results =
        try do
          state.executor_fn.(unique_requests)
        rescue
          error ->
            Logger.error("Batch execution failed",
              operation_type: state.operation_type,
              error: inspect(error)
            )

            Map.new(unique_requests, fn req_id -> {req_id, {:error, :batch_failed}} end)
        end

      execution_time_ms = System.monotonic_time(:millisecond) - start_time

      for {request_id, waiters} <- batch.requests do
        result = Map.get(results, request_id, {:error, :no_result})

        Enum.each(waiters, fn {pid, ref} ->
          send(pid, {:batch_result, ref, result})
        end)
      end

      dedup_savings = total_waiters - unique_count
      dedup_pct = if total_waiters > 0, do: dedup_savings / total_waiters * 100.0, else: 0.0

      Logger.debug("Batch flushed",
        batch_count: length(batch),
        total_waiters: total_waiters,
        dedup_savings: dedup_savings,
        dedup_percentage: Float.round(dedup_pct, 2)
      )

      new_metrics =
        state.metrics
        |> Map.update!(:total_requests, &(&1 + total_waiters))
        |> Map.update!(:total_batches, &(&1 + 1))
        |> Map.update!(:total_deduped, &(&1 + dedup_savings))

      :telemetry.execute(
        [:orchestrator, :request_coalescer, :batch_flushed],
        %{
          batch_size: unique_count,
          total_waiters: total_waiters,
          dedup_savings: dedup_savings,
          execution_time_ms: execution_time_ms
        },
        %{operation_type: state.operation_type}
      )

      %{
        state
        | pending_batch: nil,
          flush_timer_ref: nil,
          metrics: new_metrics
      }
    end
  end

  defp estimate_request_size(request) do
    (:erlang.external_size(request) * 1.2) |> round()
  end

  defp initialize_metrics do
    %{
      total_requests: 0,
      total_batches: 0,
      total_deduped: 0
    }
  end

  defp compile_stats(state) do
    total_requests = state.metrics.total_requests
    total_batches = state.metrics.total_batches
    total_deduped = state.metrics.total_deduped

    avg_batch_size = if total_batches > 0, do: total_requests / total_batches, else: 0.0

    rpc_reduction_ratio = if total_batches > 0, do: total_requests / total_batches, else: 1.0

    dedup_savings_pct =
      if total_requests > 0, do: total_deduped / total_requests * 100.0, else: 0.0

    %{
      operation_type: state.operation_type,
      total_requests: total_requests,
      total_batches: total_batches,
      avg_batch_size: Float.round(avg_batch_size, 1),
      rpc_reduction_ratio: Float.round(rpc_reduction_ratio, 1),
      dedup_savings_pct: Float.round(dedup_savings_pct, 2),
      pending_batch_size:
        if(state.pending_batch, do: map_size(state.pending_batch.requests), else: 0)
    }
  end
end
