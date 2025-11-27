defmodule Orchestrator.Metrics.TelemetryCollector do
  use GenServer
  require Logger
  alias Orchestrator.Metrics.{MetricDefinition, MetricSample}
  @type metric_type :: :counter | :gauge | :histogram | :summary
  @type labels :: %{atom() => String.t()}
  @type metric_value :: float() | integer()
  @default_batch_size 1000
  @default_flush_interval 1000
  @default_max_buffer_size 10_000
  @default_sampling_rate 1.0
  @circuit_breaker_failure_threshold 10
  @circuit_breaker_success_threshold 5
  @circuit_breaker_timeout 30_000
  @default_histogram_buckets [
    1,
    5,
    10,
    25,
    50,
    100,
    250,
    500,
    1000,
    2500,
    5000,
    10000
  ]
  @default_summary_quantiles [0.5, 0.9, 0.95, 0.99]
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec increment(String.t(), metric_value(), labels()) :: :ok
  def increment(name, value \\ 1, labels \\ %{}) do
    emit(:counter, name, value, labels)
  end

  @spec set_gauge(String.t(), metric_value(), labels()) :: :ok
  def set_gauge(name, value, labels \\ %{}) do
    emit(:gauge, name, value, labels)
  end

  @spec observe(String.t(), metric_value(), labels()) :: :ok
  def observe(name, value, labels \\ %{}) do
    emit(:histogram, name, value, labels)
  end

  @spec observe_summary(String.t(), metric_value(), labels()) :: :ok
  def observe_summary(name, value, labels \\ %{}) do
    emit(:summary, name, value, labels)
  end

  @spec record_batch([{metric_type(), String.t(), metric_value(), labels()}]) :: :ok
  def record_batch(metrics) do
    GenServer.cast(__MODULE__, {:batch_record, metrics})
  end

  @spec register_metric(map()) :: {:ok, MetricDefinition.t()} | {:error, term()}
  def register_metric(attrs) do
    GenServer.call(__MODULE__, {:register_metric, attrs})
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @spec circuit_breaker_status() :: :closed | :open | :half_open
  def circuit_breaker_status do
    GenServer.call(__MODULE__, :circuit_breaker_status)
  end

  defp emit(type, name, value, labels) do
    GenServer.cast(__MODULE__, {:emit, type, name, value, labels, System.monotonic_time()})
  end

  @impl true
  def init(opts) do
    flush_interval = Keyword.get(opts, :flush_interval, @default_flush_interval)
    schedule_flush(flush_interval)

    state = %{
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      flush_interval: flush_interval,
      max_buffer_size: Keyword.get(opts, :max_buffer_size, @default_max_buffer_size),
      sampling_rate: Keyword.get(opts, :sampling_rate, @default_sampling_rate),
      buffer: [],
      buffer_size: 0,
      aggregation_cache: %{},
      metric_definitions: load_metric_definitions(),
      circuit_breaker: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      stats: %{
        metrics_received: 0,
        metrics_flushed: 0,
        metrics_dropped: 0,
        metrics_sampled_out: 0,
        flush_count: 0,
        last_flush_duration_ms: 0,
        errors: 0,
        circuit_breaker_opens: 0
      }
    }

    Logger.info(
      "TelemetryCollector started with batch_size=#{state.batch_size}, flush_interval=#{state.flush_interval}ms"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:emit, type, name, value, labels, timestamp}, state) do
    if should_sample?(state.sampling_rate) do
      state = update_in(state.stats.metrics_received, &(&1 + 1))
      metric_def = get_or_create_metric(name, type, labels, state)

      metric_entry = %{
        type: type,
        name: name,
        metric_id: metric_def.id,
        value: value,
        labels: labels,
        timestamp: timestamp
      }

      state = %{state | buffer: [metric_entry | state.buffer], buffer_size: state.buffer_size + 1}

      state =
        if state.buffer_size >= state.batch_size do
          flush_buffer(state)
        else
          state
        end

      {:noreply, state}
    else
      state = update_in(state.stats.metrics_sampled_out, &(&1 + 1))
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:batch_record, metrics}, state) do
    timestamp = System.monotonic_time()

    Enum.reduce(metrics, state, fn {type, name, value, labels}, acc_state ->
      handle_cast({:emit, type, name, value, labels, timestamp}, acc_state)
      |> elem(1)
    end)
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_call({:register_metric, attrs}, _from, state) do
    case MetricDefinition.create(attrs) do
      {:ok, metric_def} ->
        state = put_in(state.metric_definitions[attrs.name], metric_def)
        {:reply, {:ok, metric_def}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = flush_buffer(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        buffer_size: state.buffer_size,
        circuit_breaker: state.circuit_breaker,
        metric_definitions_count: map_size(state.metric_definitions)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:circuit_breaker_status, _from, state) do
    {:reply, state.circuit_breaker, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = flush_buffer(state)
    schedule_flush(state.flush_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:circuit_breaker_timeout, breaker_state}, state) do
    if state.circuit_breaker == :open and breaker_state == :open do
      Logger.info("Circuit breaker transitioning to half-open")
      {:noreply, %{state | circuit_breaker: :half_open, success_count: 0}}
    else
      {:noreply, state}
    end
  end

  defp load_metric_definitions do
    MetricDefinition.list_enabled()
    |> Enum.map(&{&1.name, &1})
    |> Map.new()
  rescue
    _ ->
      Logger.warning("Could not load metric definitions, starting with empty cache")
      %{}
  end

  defp get_or_create_metric(name, type, labels, state) do
    case Map.get(state.metric_definitions, name) do
      nil ->
        label_keys = Map.keys(labels) |> Enum.map(&Atom.to_string/1)

        attrs = %{
          name: name,
          type: type_to_string(type),
          label_keys: label_keys,
          help: "Auto-generated metric: #{name}",
          enabled: true
        }

        case MetricDefinition.create(attrs) do
          {:ok, metric_def} ->
            metric_def

          {:error, changeset} ->
            Logger.error("Failed to create metric definition: #{inspect(changeset.errors)}")
            %MetricDefinition{id: nil, name: name}
        end

      metric_def ->
        metric_def
    end
  end

  defp flush_buffer(%{buffer: []} = state), do: state

  defp flush_buffer(state) do
    start_time = System.monotonic_time()

    case state.circuit_breaker do
      :open ->
        if should_attempt_recovery?(state) do
          state = %{state | circuit_breaker: :half_open, success_count: 0}
          do_flush(state, start_time)
        else
          dropped_count = state.buffer_size
          Logger.warning("Circuit breaker OPEN: Dropping #{dropped_count} buffered metrics")

          state
          |> update_in([Access.key!(:stats), :metrics_dropped], &(&1 + dropped_count))
          |> Map.put(:buffer, [])
          |> Map.put(:buffer_size, 0)
        end

      _ ->
        do_flush(state, start_time)
    end
  end

  defp do_flush(state, start_time) do
    metrics = Enum.reverse(state.buffer)
    grouped = Enum.group_by(metrics, & &1.type)

    results = %{
      counters: process_counters(grouped[:counter] || []),
      gauges: process_gauges(grouped[:gauge] || []),
      histograms: process_histograms(grouped[:histogram] || []),
      summaries: process_summaries(grouped[:summary] || [])
    }

    all_samples =
      Enum.flat_map(results, fn {_type, samples} -> samples end)

    result =
      if length(all_samples) > 0 do
        MetricSample.record_batch(all_samples, %{})
      else
        {:ok, 0}
      end

    end_time = System.monotonic_time()
    duration_ms = System.convert_time_unit(end_time - start_time, :native, :millisecond)

    case result do
      {:ok, inserted_count} ->
        handle_flush_success(state, duration_ms, inserted_count)

      {:error, reason} ->
        handle_flush_error(state, reason)
    end
  end

  defp process_counters(counters) do
    counters
    |> Enum.group_by(
      fn m -> {m.metric_id, hash_labels(m.labels)} end,
      fn m -> m.value end
    )
    |> Enum.map(fn {{metric_id, labels_hash}, values} ->
      counter = Enum.at(counters, 0)

      %{
        metric_id: metric_id,
        timestamp: convert_monotonic_to_datetime(counter.timestamp),
        value: Enum.sum(values),
        labels: counter.labels,
        labels_hash: labels_hash
      }
    end)
  end

  defp process_gauges(gauges) do
    gauges
    |> Enum.group_by(fn m -> {m.metric_id, hash_labels(m.labels)} end)
    |> Enum.map(fn {{metric_id, labels_hash}, grouped_gauges} ->
      latest = Enum.max_by(grouped_gauges, & &1.timestamp)

      %{
        metric_id: metric_id,
        timestamp: convert_monotonic_to_datetime(latest.timestamp),
        value: latest.value,
        labels: latest.labels,
        labels_hash: labels_hash
      }
    end)
  end

  defp process_histograms(histograms) do
    histograms
    |> Enum.group_by(fn m -> {m.metric_id, hash_labels(m.labels)} end)
    |> Enum.map(fn {{metric_id, labels_hash}, grouped_histograms} ->
      values = Enum.map(grouped_histograms, & &1.value)
      first = Enum.at(grouped_histograms, 0)
      bucket_values = calculate_histogram_buckets(values, @default_histogram_buckets)

      %{
        metric_id: metric_id,
        timestamp: convert_monotonic_to_datetime(first.timestamp),
        labels: first.labels,
        labels_hash: labels_hash,
        bucket_values: bucket_values,
        count: length(values),
        sum: Enum.sum(values)
      }
    end)
  end

  defp process_summaries(summaries) do
    summaries
    |> Enum.group_by(fn m -> {m.metric_id, hash_labels(m.labels)} end)
    |> Enum.map(fn {{metric_id, labels_hash}, grouped_summaries} ->
      values = Enum.map(grouped_summaries, & &1.value) |> Enum.sort()
      first = Enum.at(grouped_summaries, 0)
      quantile_values = calculate_quantiles(values, @default_summary_quantiles)

      %{
        metric_id: metric_id,
        timestamp: convert_monotonic_to_datetime(first.timestamp),
        labels: first.labels,
        labels_hash: labels_hash,
        quantile_values: quantile_values,
        count: length(values),
        sum: Enum.sum(values)
      }
    end)
  end

  defp calculate_histogram_buckets(values, buckets) do
    buckets
    |> Enum.map(fn bucket ->
      count = Enum.count(values, fn v -> v <= bucket end)
      %{le: bucket, count: count}
    end)
  end

  defp calculate_quantiles(sorted_values, quantiles) when length(sorted_values) == 0 do
    Enum.map(quantiles, fn q -> %{quantile: q, value: 0.0} end)
  end

  defp calculate_quantiles(sorted_values, quantiles) do
    n = length(sorted_values)

    Enum.map(quantiles, fn q ->
      index = ceil(q * n) - 1
      index = max(0, min(index, n - 1))
      value = Enum.at(sorted_values, index)
      %{quantile: q, value: value}
    end)
  end

  defp hash_labels(labels) when labels == %{}, do: ""

  defp hash_labels(labels) do
    labels
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> "#{k}=\"#{v}\"" end)
    |> Enum.join(",")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0..15)
  end

  defp convert_monotonic_to_datetime(monotonic_time) do
    system_time = System.convert_time_unit(monotonic_time, :native, :microsecond)
    DateTime.from_unix!(system_time, :microsecond)
  end

  defp handle_flush_success(state, duration_ms, inserted_count) do
    Logger.debug(
      "Flushed #{inserted_count} metrics in #{duration_ms}ms (buffer size: #{state.buffer_size})"
    )

    state =
      state
      |> update_in([Access.key!(:stats), :metrics_flushed], &(&1 + inserted_count))
      |> update_in([Access.key!(:stats), :flush_count], &(&1 + 1))
      |> put_in([Access.key!(:stats), :last_flush_duration_ms], duration_ms)
      |> Map.put(:buffer, [])
      |> Map.put(:buffer_size, 0)

    case state.circuit_breaker do
      :half_open ->
        success_count = state.success_count + 1

        if success_count >= @circuit_breaker_success_threshold do
          Logger.info("Circuit breaker CLOSED after #{success_count} successes")
          %{state | circuit_breaker: :closed, success_count: 0, failure_count: 0}
        else
          %{state | success_count: success_count}
        end

      :closed ->
        %{state | failure_count: 0}

      _ ->
        state
    end
  end

  defp handle_flush_error(state, reason) do
    Logger.error("Failed to flush metrics: #{inspect(reason)}")

    state =
      state
      |> update_in([Access.key!(:stats), :errors], &(&1 + 1))

    failure_count = state.failure_count + 1

    if failure_count >= @circuit_breaker_failure_threshold do
      Logger.error(
        "Circuit breaker OPEN after #{failure_count} failures (buffer size: #{state.buffer_size})"
      )

      Process.send_after(self(), {:circuit_breaker_timeout, :open}, @circuit_breaker_timeout)

      state
      |> update_in([Access.key!(:stats), :circuit_breaker_opens], &(&1 + 1))
      |> Map.put(:circuit_breaker, :open)
      |> Map.put(:failure_count, 0)
      |> Map.put(:last_failure_time, System.monotonic_time())
    else
      %{state | failure_count: failure_count}
    end
  end

  defp should_attempt_recovery?(state) do
    case state.last_failure_time do
      nil ->
        true

      last_failure ->
        elapsed = System.monotonic_time() - last_failure
        elapsed_ms = System.convert_time_unit(elapsed, :native, :millisecond)
        elapsed_ms >= @circuit_breaker_timeout
    end
  end

  defp should_sample?(1.0), do: true
  defp should_sample?(rate), do: :rand.uniform() <= rate

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end

  defp type_to_string(:counter), do: "counter"
  defp type_to_string(:gauge), do: "gauge"
  defp type_to_string(:histogram), do: "histogram"
  defp type_to_string(:summary), do: "summary"
end
