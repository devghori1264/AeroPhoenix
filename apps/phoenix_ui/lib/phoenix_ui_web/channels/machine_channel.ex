defmodule PhoenixUiWeb.MachineChannel do
  use Phoenix.Channel
  require Logger

  alias __MODULE__.{CircularBuffer, TokenBucket}

  @default_rate_limit 100
  @buffer_size 1000
  @batch_interval 50
  @max_batch_size 50

  @impl true
  def join("machine:" <> machine_id, params, socket) do
    with {:ok, _machine} <- authorize_machine_access(machine_id, socket.assigns.user_id),
         {:ok, filters} <- parse_filters(params["filters"] || %{}) do
      socket =
        socket
        |> assign(:machine_id, machine_id)
        |> assign(:filters, filters)
        |> assign(:buffer, CircularBuffer.new(@buffer_size))
        |> assign(:rate_limiter, TokenBucket.new(@default_rate_limit))
        |> assign(:paused, false)
        |> assign(:stats, %{
          total_logs: 0,
          dropped_logs: 0,
          rate_limited: 0,
          batches_sent: 0
        })

      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:#{machine_id}")

      schedule_batch_send()

      :telemetry.execute(
        [:phoenix_ui, :channel, :join],
        %{count: 1},
        %{machine_id: machine_id, user_id: socket.assigns.user_id}
      )

      {:ok, %{joined: true, machine_id: machine_id, filters: filters}, socket}
    else
      {:error, :unauthorized} ->
        {:error, %{reason: :unauthorized}}

      {:error, :machine_not_found} ->
        {:error, %{reason: :machine_not_found}}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_in("pause", _payload, socket) do
    socket = assign(socket, :paused, true)

    :telemetry.execute(
      [:phoenix_ui, :channel, :paused],
      %{count: 1},
      %{machine_id: socket.assigns.machine_id}
    )

    {:reply, {:ok, %{paused: true}}, socket}
  end

  def handle_in("resume", _payload, socket) do
    socket =
      socket
      |> assign(:paused, false)
      |> flush_buffer()

    :telemetry.execute(
      [:phoenix_ui, :channel, :resumed],
      %{count: 1},
      %{machine_id: socket.assigns.machine_id}
    )

    {:reply, {:ok, %{paused: false}}, socket}
  end

  def handle_in("filter", %{"filters" => new_filters}, socket) do
    case parse_filters(new_filters) do
      {:ok, filters} ->
        socket = assign(socket, :filters, filters)

        :telemetry.execute(
          [:phoenix_ui, :channel, :filter_updated],
          %{count: 1},
          %{machine_id: socket.assigns.machine_id, filters: filters}
        )

        {:reply, {:ok, %{filters: filters}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("get_stats", _payload, socket) do
    buffer = socket.assigns.buffer
    stats = socket.assigns.stats

    response = %{
      total_logs: stats.total_logs,
      dropped_logs: stats.dropped_logs,
      rate_limited: stats.rate_limited,
      batches_sent: stats.batches_sent,
      buffer_size: CircularBuffer.size(buffer),
      buffer_capacity: @buffer_size,
      buffer_utilization: CircularBuffer.size(buffer) / @buffer_size,
      paused: socket.assigns.paused,
      filters: socket.assigns.filters
    }

    {:reply, {:ok, response}, socket}
  end

  @impl true
  def handle_info({:log_event, log_entry}, socket) do
    socket =
      socket
      |> update_in([:assigns, :stats, :total_logs], &(&1 + 1))
      |> process_log_entry(log_entry)

    {:noreply, socket}
  end

  def handle_info(:send_batch, socket) do
    socket = maybe_send_batch(socket)
    schedule_batch_send()
    {:noreply, socket}
  end

  defp authorize_machine_access(machine_id, user_id) do
    if String.length(machine_id) > 0 do
      {:ok, %{id: machine_id, owner_id: user_id}}
    else
      {:error, :machine_not_found}
    end
  end

  defp parse_filters(filters) when is_map(filters) do
    valid_levels = ~w(debug info warn error)
    valid_components = ~w(fsm migration network storage)

    parsed = %{
      level: parse_filter_value(filters["level"], valid_levels, "info"),
      component: parse_filter_value(filters["component"], valid_components, nil)
    }

    {:ok, parsed}
  end

  defp parse_filters(_), do: {:error, :invalid_filters}

  defp parse_filter_value(nil, _valid, default), do: default

  defp parse_filter_value(value, valid, default) when is_binary(value) do
    if value in valid, do: value, else: default
  end

  defp parse_filter_value(value, valid, default) when is_atom(value) do
    str_value = to_string(value)
    if str_value in valid, do: str_value, else: default
  end

  defp parse_filter_value(_, _, default), do: default

  defp process_log_entry(socket, log_entry) do
    cond do
      not passes_filter?(log_entry, socket.assigns.filters) ->
        socket

      not TokenBucket.consume(socket.assigns.rate_limiter) ->
        socket
        |> update_in([:assigns, :stats, :rate_limited], &(&1 + 1))
        |> maybe_notify_rate_limited()

      true ->
        buffer = CircularBuffer.insert(socket.assigns.buffer, log_entry)

        socket =
          socket
          |> assign(:buffer, buffer)

        if not socket.assigns.paused and CircularBuffer.size(buffer) < @buffer_size * 0.9 do
          push(socket, "log", format_log_entry(log_entry))
        end

        socket
    end
  end

  defp passes_filter?(log_entry, filters) do
    level_match = is_nil(filters.level) or to_string(log_entry.level) == filters.level

    component_match =
      is_nil(filters.component) or to_string(log_entry.component) == filters.component

    level_match and component_match
  end

  defp maybe_send_batch(socket) do
    if socket.assigns.paused or CircularBuffer.empty?(socket.assigns.buffer) do
      socket
    else
      {batch, buffer} = CircularBuffer.take(socket.assigns.buffer, @max_batch_size)

      if length(batch) > 0 do
        push(socket, "logs", Enum.map(batch, &format_log_entry/1))

        socket
        |> assign(:buffer, buffer)
        |> update_in([:assigns, :stats, :batches_sent], &(&1 + 1))
      else
        socket
      end
    end
  end

  defp flush_buffer(socket) do
    if CircularBuffer.empty?(socket.assigns.buffer) do
      socket
    else
      {all_logs, buffer} = CircularBuffer.take_all(socket.assigns.buffer)

      if length(all_logs) > 0 do
        all_logs
        |> Enum.chunk_every(@max_batch_size)
        |> Enum.each(fn batch ->
          push(socket, "logs", Enum.map(batch, &format_log_entry/1))
        end)
      end

      assign(socket, :buffer, buffer)
    end
  end

  defp format_log_entry(log) do
    %{
      timestamp: log.timestamp,
      level: log.level,
      component: log.component,
      message: log.message,
      metadata: log.metadata || %{}
    }
  end

  defp maybe_notify_rate_limited(socket) do
    last_notification = socket.assigns[:last_rate_limit_notification] || 0
    now = System.system_time(:second)

    if now - last_notification >= 1 do
      push(socket, "rate_limited", %{
        current_rate: @default_rate_limit,
        limit: @default_rate_limit
      })

      assign(socket, :last_rate_limit_notification, now)
    else
      socket
    end
  end

  defp schedule_batch_send do
    Process.send_after(self(), :send_batch, @batch_interval)
  end

  defmodule CircularBuffer do
    defstruct [:data, :head, :tail, :size, :capacity]

    def new(capacity) do
      %__MODULE__{
        data: :array.new(capacity, default: nil),
        head: 0,
        tail: 0,
        size: 0,
        capacity: capacity
      }
    end

    def insert(%__MODULE__{} = buffer, item) do
      data = :array.set(buffer.tail, item, buffer.data)
      tail = rem(buffer.tail + 1, buffer.capacity)

      {head, size} =
        if buffer.size == buffer.capacity do
          {rem(buffer.head + 1, buffer.capacity), buffer.size}
        else
          {buffer.head, buffer.size + 1}
        end

      %{buffer | data: data, head: head, tail: tail, size: size}
    end

    def take(%__MODULE__{size: 0} = buffer, _count), do: {[], buffer}

    def take(%__MODULE__{} = buffer, count) do
      actual_count = min(count, buffer.size)

      items =
        Enum.map(0..(actual_count - 1), fn i ->
          index = rem(buffer.head + i, buffer.capacity)
          :array.get(index, buffer.data)
        end)

      head = rem(buffer.head + actual_count, buffer.capacity)
      size = buffer.size - actual_count

      {items, %{buffer | head: head, size: size}}
    end

    def take_all(%__MODULE__{} = buffer) do
      take(buffer, buffer.size)
    end

    def size(%__MODULE__{size: size}), do: size

    def empty?(%__MODULE__{size: 0}), do: true
    def empty?(%__MODULE__{}), do: false
  end

  defmodule TokenBucket do
    defstruct [:capacity, :tokens, :last_refill]

    def new(capacity) do
      %__MODULE__{
        capacity: capacity,
        tokens: capacity,
        last_refill: System.system_time(:millisecond)
      }
    end

    def consume(%__MODULE__{} = bucket) do
      bucket = refill(bucket)

      if bucket.tokens >= 1 do
        %{bucket | tokens: bucket.tokens - 1}
        true
      else
        false
      end
    end

    defp refill(%__MODULE__{} = bucket) do
      now = System.system_time(:millisecond)
      elapsed = now - bucket.last_refill

      tokens_to_add = elapsed / 1000 * bucket.capacity
      new_tokens = min(bucket.tokens + tokens_to_add, bucket.capacity)

      %{bucket | tokens: new_tokens, last_refill: now}
    end
  end
end
