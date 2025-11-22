defmodule Orchestrator.Replication.StateSync do
  use GenServer
  require Logger
  alias Orchestrator.Replication.{CRDT, QuorumManager}
  @batch_size 100
  @sync_interval 1_000
  @max_retries 5
  @backoff_base 1_000
  defmodule State do
    @moduledoc false
    defstruct [
      :source_region,
      :target_regions,
      :pending_changes,
      :sync_queue,
      :retry_queue,
      :last_sync_time,
      :statistics
    ]
  end

  defmodule Change do
    @moduledoc false
    defstruct [:id, :key, :operation, :value, :timestamp, :vector_clock, :retry_count]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def record_change(key, operation, value, vector_clock \\ nil) do
    GenServer.cast(__MODULE__, {:record_change, key, operation, value, vector_clock})
  end

  def sync_now do
    GenServer.call(__MODULE__, :sync_now)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def init(opts) do
    source_region = Keyword.fetch!(opts, :source_region)
    target_regions = Keyword.get(opts, :target_regions, [])

    state = %State{
      source_region: source_region,
      target_regions: target_regions,
      pending_changes: [],
      sync_queue: :queue.new(),
      retry_queue: :queue.new(),
      last_sync_time: DateTime.utc_now(),
      statistics: %{
        changes_synced: 0,
        sync_failures: 0,
        retries: 0,
        bytes_transferred: 0
      }
    }

    schedule_sync()
    {:ok, state}
  end

  @impl true
  def handle_cast({:record_change, key, operation, value, vector_clock}, state) do
    change = %Change{
      id: UUID.uuid4(),
      key: key,
      operation: operation,
      value: value,
      timestamp: DateTime.utc_now(),
      vector_clock: vector_clock || CRDT.VectorClock.new(),
      retry_count: 0
    }

    new_pending = [change | state.pending_changes]
    new_state = %{state | pending_changes: new_pending}

    new_state =
      if length(new_pending) >= @batch_size do
        flush_pending_changes(new_state)
      else
        new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    new_state = flush_pending_changes(state)
    new_state = process_sync_queue(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.statistics, state}
  end

  @impl true
  def handle_info(:periodic_sync, state) do
    new_state = flush_pending_changes(state)
    new_state = process_sync_queue(new_state)
    new_state = process_retry_queue(new_state)
    schedule_sync()
    {:noreply, new_state}
  end

  defp schedule_sync do
    Process.send_after(self(), :periodic_sync, @sync_interval)
  end

  defp flush_pending_changes(%{pending_changes: []} = state), do: state

  defp flush_pending_changes(state) do
    new_queue =
      Enum.reduce(state.pending_changes, state.sync_queue, fn change, queue ->
        :queue.in(change, queue)
      end)

    %{state | pending_changes: [], sync_queue: new_queue}
  end

  defp process_sync_queue(state) do
    {batch, new_queue} = take_batch(state.sync_queue, @batch_size)

    if batch == [] do
      state
    else
      Logger.debug("Syncing #{length(batch)} changes to #{length(state.target_regions)} regions")

      results =
        Enum.map(state.target_regions, fn region ->
          sync_batch_to_region(batch, region, state.source_region)
        end)

      failed_changes =
        results
        |> Enum.filter(fn {status, _} -> status == :error end)
        |> Enum.flat_map(fn {_, changes} -> changes end)

      new_retry_queue =
        Enum.reduce(failed_changes, state.retry_queue, fn change, queue ->
          updated_change = %{change | retry_count: change.retry_count + 1}
          :queue.in(updated_change, queue)
        end)

      successful = length(batch) * length(state.target_regions) - length(failed_changes)
      bytes = estimate_batch_size(batch)

      new_stats = %{
        state.statistics
        | changes_synced: state.statistics.changes_synced + successful,
          sync_failures: state.statistics.sync_failures + length(failed_changes),
          bytes_transferred: state.statistics.bytes_transferred + bytes
      }

      %{
        state
        | sync_queue: new_queue,
          retry_queue: new_retry_queue,
          statistics: new_stats,
          last_sync_time: DateTime.utc_now()
      }
    end
  end

  defp process_retry_queue(state) do
    {to_retry, new_queue} = take_retryable(state.retry_queue)

    if to_retry == [] do
      state
    else
      Logger.debug("Retrying #{length(to_retry)} failed changes")

      results =
        Enum.map(state.target_regions, fn region ->
          sync_batch_to_region(to_retry, region, state.source_region)
        end)

      failed_changes =
        results
        |> Enum.filter(fn {status, _} -> status == :error end)
        |> Enum.flat_map(fn {_, changes} -> changes end)

      new_retry_queue =
        Enum.reduce(failed_changes, new_queue, fn change, queue ->
          if change.retry_count < @max_retries do
            updated_change = %{change | retry_count: change.retry_count + 1}
            :queue.in(updated_change, queue)
          else
            Logger.error("Max retries exceeded for change #{change.id}, dropping")
            queue
          end
        end)

      new_stats = %{
        state.statistics
        | retries: state.statistics.retries + length(to_retry)
      }

      %{state | retry_queue: new_retry_queue, statistics: new_stats}
    end
  end

  defp sync_batch_to_region(changes, target_region, source_region) do
    compressed = compress_changes(changes)
    result = simulate_network_transfer(compressed, target_region, source_region)

    case result do
      :ok ->
        {:ok, []}

      {:error, _reason} ->
        {:error, changes}
    end
  end

  defp compress_changes(changes) do
    Enum.map(changes, fn change ->
      %{
        id: change.id,
        key: change.key,
        op: change.operation,
        val: change.value,
        ts: DateTime.to_unix(change.timestamp, :millisecond),
        vc: encode_vector_clock(change.vector_clock)
      }
    end)
  end

  defp encode_vector_clock(%CRDT.VectorClock{clocks: clocks}) do
    clocks
  end

  defp encode_vector_clock(_), do: %{}

  defp simulate_network_transfer(compressed_changes, _target_region, _source_region) do
    :timer.sleep(:rand.uniform(50))

    if :rand.uniform(100) > 5 do
      :ok
    else
      {:error, :network_error}
    end
  end

  defp take_batch(queue, max_size) do
    take_batch_recursive(queue, max_size, [])
  end

  defp take_batch_recursive(queue, 0, acc) do
    {Enum.reverse(acc), queue}
  end

  defp take_batch_recursive(queue, remaining, acc) do
    case :queue.out(queue) do
      {{:value, item}, new_queue} ->
        take_batch_recursive(new_queue, remaining - 1, [item | acc])

      {:empty, queue} ->
        {Enum.reverse(acc), queue}
    end
  end

  defp take_retryable(queue) do
    now = DateTime.utc_now()

    {to_retry, remaining} =
      :queue.to_list(queue)
      |> Enum.split_with(fn change ->
        backoff = (@backoff_base * :math.pow(2, change.retry_count)) |> round()
        elapsed = DateTime.diff(now, change.timestamp, :millisecond)
        elapsed >= backoff
      end)

    {to_retry, :queue.from_list(remaining)}
  end

  defp estimate_batch_size(changes) do
    changes
    |> Enum.map(fn change ->
      String.length(change.key) + byte_size(:erlang.term_to_binary(change.value)) + 100
    end)
    |> Enum.sum()
  end
end
