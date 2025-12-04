defmodule Orchestrator.Logs.Aggregator do
  use GenServer
  require Logger

  @buffer_size 100_000
  @batch_size 100
  @batch_interval 100

  defstruct [
    :buffer,
    :stats,
    :batch_timer,
    :storage_pid
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_recent_logs(limit \\ 100, filters \\ []) do
    GenServer.call(__MODULE__, {:get_recent_logs, limit, filters})
  end

  def get_machine_logs(machine_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_machine_logs, machine_id, opts})
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(opts) do
    buffer_capacity = Keyword.get(opts, :buffer_size, @buffer_size)
    batch_interval = Keyword.get(opts, :batch_interval, @batch_interval)

    Phoenix.PubSub.subscribe(Orchestrator.PubSub, "log_aggregator:all_machines")

    state = %__MODULE__{
      buffer: :queue.new(),
      stats: %{
        total_received: 0,
        total_stored: 0,
        total_dropped: 0,
        batches_written: 0,
        bytes_received: 0,
        bytes_stored: 0,
        compression_ratio: 0.0,
        start_time: System.system_time(:second),
        buffer_capacity: buffer_capacity,
        batch_interval: batch_interval
      },
      batch_timer: schedule_batch_write(batch_interval),
      storage_pid: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:log_event, log}, state) do
    buffer = :queue.in(log, state.buffer)
    buffer_size = :queue.len(buffer)

    stats = %{
      state.stats
      | total_received: state.stats.total_received + 1,
        bytes_received: state.stats.bytes_received + estimate_log_size(log)
    }

    {buffer, stats} =
      if buffer_size > state.stats.buffer_capacity do
        {{:value, _dropped}, new_buffer} = :queue.out(buffer)

        new_stats = %{stats | total_dropped: stats.total_dropped + 1}

        :telemetry.execute(
          [:orchestrator, :logs, :dropped],
          %{count: 1},
          %{reason: :buffer_full}
        )

        {new_buffer, new_stats}
      else
        {buffer, stats}
      end

    {:noreply, %{state | buffer: buffer, stats: stats}}
  end

  @impl true
  def handle_info(:write_batch, state) do
    state = write_batch_to_storage(state)

    batch_timer = schedule_batch_write(state.stats.batch_interval)

    {:noreply, %{state | batch_timer: batch_timer}}
  end

  @impl true
  def handle_call({:get_recent_logs, limit, filters}, _from, state) do
    buffer_logs =
      state.buffer
      |> :queue.to_list()
      |> Enum.reverse()
      |> apply_filters(filters)
      |> Enum.take(limit)

    {:reply, buffer_logs, state}
  end

  @impl true
  def handle_call({:get_machine_logs, machine_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)

    buffer_logs =
      state.buffer
      |> :queue.to_list()
      |> Enum.filter(fn log ->
        Map.get(log.metadata, :machine_id) == machine_id
      end)
      |> Enum.reverse()
      |> Enum.take(limit)

    {:reply, buffer_logs, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    buffer_size = :queue.len(state.buffer)
    uptime = System.system_time(:second) - state.stats.start_time

    stats = %{
      total_logs_received: state.stats.total_received,
      total_logs_stored: state.stats.total_stored,
      total_logs_dropped: state.stats.total_dropped,
      buffer_size: buffer_size,
      buffer_capacity: state.stats.buffer_capacity,
      buffer_utilization: buffer_size / max(state.stats.buffer_capacity, 1),
      batches_written: state.stats.batches_written,
      compression_ratio: state.stats.compression_ratio,
      avg_batch_size:
        if(state.stats.batches_written > 0,
          do: state.stats.total_stored / state.stats.batches_written,
          else: 0.0
        ),
      bytes_received: state.stats.bytes_received,
      bytes_stored: state.stats.bytes_stored,
      uptime_seconds: uptime,
      logs_per_second: if(uptime > 0, do: state.stats.total_received / uptime, else: 0.0)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = write_batch_to_storage(state)
    {:reply, :ok, state}
  end

  defp write_batch_to_storage(state) do
    buffer_size = :queue.len(state.buffer)

    if buffer_size == 0 do
      state
    else
      batch_size = min(buffer_size, @batch_size)

      {batch, remaining_buffer} = extract_batch(state.buffer, batch_size)

      {compressed, compression_ratio} = compress_batch(batch)

      :telemetry.execute(
        [:orchestrator, :logs, :batch_written],
        %{count: length(batch), bytes: byte_size(compressed)},
        %{compression_ratio: compression_ratio}
      )

      stats = %{
        state.stats
        | total_stored: state.stats.total_stored + length(batch),
          batches_written: state.stats.batches_written + 1,
          bytes_stored: state.stats.bytes_stored + byte_size(compressed),
          compression_ratio:
            calculate_avg_compression_ratio(
              state.stats.compression_ratio,
              state.stats.batches_written,
              compression_ratio
            )
      }

      %{state | buffer: remaining_buffer, stats: stats}
    end
  end

  defp extract_batch(queue, count) do
    {batch, remaining} = extract_batch_recursive(queue, count, [])
    {Enum.reverse(batch), remaining}
  end

  defp extract_batch_recursive(queue, 0, acc), do: {acc, queue}

  defp extract_batch_recursive(queue, count, acc) do
    case :queue.out(queue) do
      {{:value, item}, new_queue} ->
        extract_batch_recursive(new_queue, count - 1, [item | acc])

      {:empty, queue} ->
        {acc, queue}
    end
  end

  defp compress_batch(logs) do
    json = Jason.encode!(logs)
    original_size = byte_size(json)

    compressed = :zlib.gzip(json)
    compressed_size = byte_size(compressed)

    ratio = original_size / max(compressed_size, 1)

    {compressed, ratio}
  end

  defp calculate_avg_compression_ratio(current_avg, batch_count, new_ratio) do
    if batch_count == 0 do
      new_ratio
    else
      (current_avg * batch_count + new_ratio) / (batch_count + 1)
    end
  end

  defp apply_filters(logs, filters) do
    logs
    |> maybe_filter_level(Keyword.get(filters, :level))
    |> maybe_filter_component(Keyword.get(filters, :component))
    |> maybe_filter_since(Keyword.get(filters, :since))
  end

  defp maybe_filter_level(logs, nil), do: logs

  defp maybe_filter_level(logs, level) do
    Enum.filter(logs, fn log -> log.level == level end)
  end

  defp maybe_filter_component(logs, nil), do: logs

  defp maybe_filter_component(logs, component) do
    Enum.filter(logs, fn log -> log.component == component end)
  end

  defp maybe_filter_since(logs, nil), do: logs

  defp maybe_filter_since(logs, since_timestamp) do
    Enum.filter(logs, fn log -> log.timestamp >= since_timestamp end)
  end

  defp estimate_log_size(log) do
    byte_size(log.message) +
      (log.metadata |> Jason.encode!() |> byte_size()) +
      100
  end

  defp schedule_batch_write(interval) do
    Process.send_after(self(), :write_batch, interval)
  end
end
