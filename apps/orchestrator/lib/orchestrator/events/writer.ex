defmodule Orchestrator.Events.Writer do
  use GenServer
  require Logger
  alias Orchestrator.Events.Event
  alias Orchestrator.Repo
  import Ecto.Query

  @type event_attrs :: %{
          required(:aggregate_id) => binary(),
          required(:aggregate_type) => String.t(),
          required(:event_type) => atom(),
          required(:data) => map(),
          optional(:metadata) => map(),
          optional(:correlation_id) => binary(),
          optional(:causation_id) => binary(),
          optional(:actor_id) => binary(),
          optional(:actor_type) => String.t(),
          optional(:tags) => list(String.t()),
          optional(:occurred_at) => DateTime.t()
        }
  @type append_result :: {:ok, Event.t()} | {:error, term()}
  @type batch_result :: {:ok, list(Event.t())} | {:error, term()}
  @default_batch_size 100
  @default_flush_interval 50
  @default_max_retries 3
  @default_retry_backoff 100
  defmodule State do
    @moduledoc false
    defstruct buffer: [],
              buffer_size: 0,
              batch_size: @default_batch_size,
              flush_interval: @default_flush_interval,
              flush_timer: nil,
              max_retries: @default_max_retries,
              retry_backoff: @default_retry_backoff,
              pending_responses: %{},
              metrics: %{
                total_events: 0,
                total_batches: 0,
                failed_writes: 0,
                avg_batch_size: 0.0,
                avg_write_time_ms: 0.0
              }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec append(event_attrs()) :: :ok
  def append(attrs) do
    GenServer.cast(__MODULE__, {:append, attrs})
  end

  @spec append_sync(event_attrs(), timeout()) :: append_result()
  def append_sync(attrs, timeout \\ 5000) do
    GenServer.call(__MODULE__, {:append_sync, attrs}, timeout)
  end

  @spec append_batch(list(event_attrs()), timeout()) :: batch_result()
  def append_batch(events, timeout \\ 10000) do
    GenServer.call(__MODULE__, {:append_batch, events}, timeout)
  end

  @spec flush(timeout()) :: :ok
  def flush(timeout \\ 5000) do
    GenServer.call(__MODULE__, :flush, timeout)
  end

  @spec metrics() :: map()
  def metrics do
    GenServer.call(__MODULE__, :metrics)
  end

  @impl true
  def init(opts) do
    state = %State{
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      flush_interval: Keyword.get(opts, :flush_interval, @default_flush_interval),
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      retry_backoff: Keyword.get(opts, :retry_backoff, @default_retry_backoff)
    }

    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_cast({:append, attrs}, state) do
    event = build_event(attrs, state)
    buffer = [event | state.buffer]
    buffer_size = state.buffer_size + 1
    state = %{state | buffer: buffer, buffer_size: buffer_size}

    if buffer_size >= state.batch_size do
      {:noreply, flush_buffer(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:append_sync, attrs}, from, state) do
    event = build_event(attrs, state)

    case persist_event(event) do
      {:ok, persisted_event} ->
        {:reply, {:ok, persisted_event}, state}

      {:error, reason} = error ->
        Logger.error("Failed to persist event synchronously", event_id: event.id, error: reason)
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:append_batch, event_attrs_list}, from, state) do
    case persist_batch(event_attrs_list, state) do
      {:ok, events} ->
        {:reply, {:ok, events}, update_metrics(state, length(events))}

      {:error, reason} = error ->
        Logger.error("Failed to persist event batch", error: reason)
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:flush, from, state) do
    state = flush_buffer(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:metrics, from, state) do
    {:reply, state.metrics, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = flush_buffer(state)
    {:noreply, schedule_flush(state)}
  end

  defp build_event(attrs, _state) do
    %Event{
      id: attrs[:id] || Ecto.UUID.generate(),
      event_type: attrs[:event_type],
      event_version: attrs[:event_version] || 1,
      aggregate_id: attrs[:aggregate_id],
      aggregate_type: attrs[:aggregate_type],
      aggregate_version: get_next_version(attrs[:aggregate_id]),
      data: attrs[:data] || %{},
      metadata: attrs[:metadata] || %{},
      causation_id: attrs[:causation_id],
      correlation_id: attrs[:correlation_id] || Ecto.UUID.generate(),
      vector_clock: build_vector_clock(attrs),
      actor_id: attrs[:actor_id],
      actor_type: attrs[:actor_type],
      occurred_at: attrs[:occurred_at] || DateTime.utc_now(),
      tags: attrs[:tags] || []
    }
  end

  defp get_next_version(aggregate_id) do
    Event.latest_version(aggregate_id) + 1
  end

  defp build_vector_clock(attrs) do
    %{
      node: node() |> Atom.to_string(),
      timestamp: System.system_time(:millisecond),
      sequence: :erlang.unique_integer([:positive, :monotonic])
    }
  end

  defp flush_buffer(%{buffer: []} = state), do: state

  defp flush_buffer(%{buffer: buffer} = state) do
    start_time = System.monotonic_time(:millisecond)

    case persist_events(Enum.reverse(buffer)) do
      {:ok, count} ->
        end_time = System.monotonic_time(:millisecond)
        write_time = end_time - start_time

        Logger.debug("Flushed event batch",
          count: count,
          write_time_ms: write_time,
          avg_time_ms: write_time / count
        )

        %{
          state
          | buffer: [],
            buffer_size: 0,
            metrics: update_batch_metrics(state.metrics, count, write_time)
        }

      {:error, reason} ->
        Logger.error("Failed to flush event buffer", error: reason, count: length(buffer))

        %{
          state
          | metrics: %{state.metrics | failed_writes: state.metrics.failed_writes + 1}
        }
    end
  end

  defp persist_event(event) do
    changeset = Event.changeset(%Event{}, Map.from_struct(event))

    case Repo.insert(changeset) do
      {:ok, persisted} -> {:ok, persisted}
      {:error, changeset} -> {:error, format_changeset_errors(changeset)}
    end
  end

  defp persist_events(events) when is_list(events) do
    changesets =
      Enum.map(events, fn event ->
        Event.changeset(%Event{}, Map.from_struct(event))
      end)

    Repo.transaction(fn ->
      Enum.reduce_while(changesets, 0, fn changeset, count ->
        case Repo.insert(changeset) do
          {:ok, _} -> {:cont, count + 1}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_batch(event_attrs_list, state) do
    events =
      event_attrs_list
      |> Enum.with_index()
      |> Enum.map(fn {attrs, index} ->
        build_event(attrs, state)
      end)

    Repo.transaction(fn ->
      Enum.map(events, fn event ->
        changeset = Event.changeset(%Event{}, Map.from_struct(event))

        case Repo.insert(changeset) do
          {:ok, persisted} ->
            persisted

          {:error, changeset} ->
            Repo.rollback(format_changeset_errors(changeset))
        end
      end)
    end)
    |> case do
      {:ok, persisted_events} -> {:ok, persisted_events}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_flush(state) do
    if state.flush_timer do
      Process.cancel_timer(state.flush_timer)
    end

    timer = Process.send_after(self(), :flush, state.flush_interval)
    %{state | flush_timer: timer}
  end

  defp update_metrics(state, event_count) do
    metrics = state.metrics
    total = metrics.total_events + event_count
    batches = metrics.total_batches + 1

    %{
      state
      | metrics: %{
          metrics
          | total_events: total,
            total_batches: batches,
            avg_batch_size: total / batches
        }
    }
  end

  defp update_batch_metrics(metrics, count, write_time) do
    total_events = metrics.total_events + count
    total_batches = metrics.total_batches + 1
    current_avg = metrics.avg_write_time_ms
    new_avg = (current_avg * metrics.total_batches + write_time) / total_batches

    %{
      metrics
      | total_events: total_events,
        total_batches: total_batches,
        avg_batch_size: total_events / total_batches,
        avg_write_time_ms: new_avg
    }
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
