defmodule Orchestrator.Metrics.Collector do
  use GenServer
  require Logger

  @type metric_name :: String.t()
  @type metric_type :: :counter | :gauge | :histogram | :summary
  @type labels :: map()
  @type value :: number()
  @histogram_buckets [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0, :infinity]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def attach_handlers do
    events = [
      [:orchestrator, :machine, :started],
      [:orchestrator, :machine, :stopped],
      [:orchestrator, :migration, :completed],
      [:orchestrator, :migration, :failed],
      [:orchestrator, :fsm, :transition],
      [:orchestrator, :crdt, :gossip_sent],
      [:orchestrator, :holodeck, :machines_spawned],
      [:orchestrator, :holodeck, :started]
    ]

    :telemetry.attach_many(
      "metrics-collector-handler",
      events,
      &__MODULE__.handle_event/4,
      nil
    )

    Logger.info("Metrics Collector: Attached telemetry handlers")
  end

  def detach_handlers do
    :telemetry.detach("metrics-collector-handler")
  end

  @spec increment_counter(metric_name(), labels(), value()) :: :ok
  def increment_counter(name, labels \\ %{}, value \\ 1) do
    GenServer.cast(__MODULE__, {:increment_counter, name, labels, value})
  end

  @spec set_gauge(metric_name(), labels(), value()) :: :ok
  def set_gauge(name, labels \\ %{}, value) do
    GenServer.cast(__MODULE__, {:set_gauge, name, labels, value})
  end

  @spec observe_histogram(metric_name(), labels(), value()) :: :ok
  def observe_histogram(name, labels \\ %{}, value) do
    GenServer.cast(__MODULE__, {:observe_histogram, name, labels, value})
  end

  @spec get_metrics() :: [map()]
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @spec prometheus_format() :: String.t()
  def prometheus_format do
    GenServer.call(__MODULE__, :prometheus_format)
  end

  @doc false
  def handle_event([:orchestrator, :machine, :started], measurements, metadata, _config) do
    increment_counter("orchestrator_machine_starts_total", %{
      region: Map.get(metadata, :region, "unknown")
    })

    if duration_ms = measurements[:duration_ms] do
      observe_histogram(
        "orchestrator_machine_start_duration_seconds",
        %{region: Map.get(metadata, :region, "unknown")},
        duration_ms / 1000
      )
    end
  end

  def handle_event([:orchestrator, :machine, :stopped], _measurements, metadata, _config) do
    increment_counter("orchestrator_machine_stops_total", %{
      region: Map.get(metadata, :region, "unknown")
    })
  end

  def handle_event([:orchestrator, :migration, :completed], measurements, metadata, _config) do
    region = Map.get(metadata, :region, "unknown")

    increment_counter("orchestrator_migrations_total", %{region: region, status: "success"})

    if duration_ms = measurements[:duration_ms] do
      observe_histogram(
        "orchestrator_migration_duration_seconds",
        %{region: region},
        duration_ms / 1000
      )
    end
  end

  def handle_event([:orchestrator, :migration, :failed], _measurements, metadata, _config) do
    increment_counter("orchestrator_migrations_total", %{
      region: Map.get(metadata, :region, "unknown"),
      status: "failure"
    })
  end

  def handle_event([:orchestrator, :fsm, :transition], measurements, metadata, _config) do
    from_state = Map.get(metadata, :from, "unknown")
    to_state = Map.get(metadata, :to, "unknown")

    increment_counter("orchestrator_fsm_transitions_total", %{from: from_state, to: to_state})

    if duration_us = measurements[:duration_us] do
      observe_histogram(
        "orchestrator_fsm_transition_duration_seconds",
        %{from: from_state, to: to_state},
        duration_us / 1_000_000
      )
    end
  end

  def handle_event([:orchestrator, :crdt, :gossip_sent], measurements, metadata, _config) do
    increment_counter("orchestrator_crdt_gossip_messages_total", %{
      node: Map.get(metadata, :node, "unknown")
    })

    if bytes = measurements[:bytes] do
      observe_histogram(
        "orchestrator_crdt_gossip_bytes",
        %{node: Map.get(metadata, :node, "unknown")},
        bytes
      )
    end
  end

  def handle_event(
        [:orchestrator, :holodeck, :machines_spawned],
        measurements,
        _metadata,
        _config
      ) do
    increment_counter("orchestrator_holodeck_spawns_total", %{}, measurements[:count] || 0)
  end

  @impl true
  def init(_opts) do
    :ets.new(:metrics_counters, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:metrics_gauges, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:metrics_histograms, [:named_table, :set, :public, read_concurrency: true])

    Logger.info("Metrics Collector started")

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:increment_counter, name, labels, value}, state) do
    key = {name, labels}

    :ets.update_counter(:metrics_counters, key, {2, value}, {key, 0})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_gauge, name, labels, value}, state) do
    key = {name, labels}

    :ets.insert(:metrics_gauges, {key, value})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:observe_histogram, name, labels, value}, state) do
    key = {name, labels}

    Enum.each(@histogram_buckets, fn bucket ->
      if value <= bucket or bucket == :infinity do
        bucket_key = {key, bucket}
        :ets.update_counter(:metrics_histograms, bucket_key, {2, 1}, {bucket_key, 0})
      end
    end)

    sum_key = {key, :sum}

    case :ets.lookup(:metrics_histograms, sum_key) do
      [{^sum_key, current_sum}] ->
        :ets.insert(:metrics_histograms, {sum_key, current_sum + value})

      [] ->
        :ets.insert(:metrics_histograms, {sum_key, value})
    end

    count_key = {key, :count}
    :ets.update_counter(:metrics_histograms, count_key, {2, 1}, {count_key, 0})

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = collect_metrics()
    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:prometheus_format, _from, state) do
    metrics = collect_metrics()

    grouped = Enum.group_by(metrics, & &1.name)

    output =
      Enum.map(grouped, fn {name, metric_list} ->
        type = hd(metric_list).type

        help_line = "# HELP #{name} #{metric_help(name)}\n"
        type_line = "# TYPE #{name} #{type}\n"

        metric_lines =
          Enum.map(metric_list, fn metric ->
            format_metric_line(metric)
          end)
          |> Enum.join("")

        help_line <> type_line <> metric_lines
      end)
      |> Enum.join("\n")

    {:reply, output, state}
  end

  defp collect_metrics do
    counters =
      :ets.tab2list(:metrics_counters)
      |> Enum.map(fn {{name, labels}, value} ->
        %{name: name, type: :counter, labels: labels, value: value}
      end)

    gauges =
      :ets.tab2list(:metrics_gauges)
      |> Enum.map(fn {{name, labels}, value} ->
        %{name: name, type: :gauge, labels: labels, value: value}
      end)

    histogram_data = :ets.tab2list(:metrics_histograms)

    histograms =
      histogram_data
      |> Enum.group_by(fn {{{name, labels}, _bucket}, _value} -> {name, labels} end)
      |> Enum.map(fn {{name, labels}, bucket_data} ->
        buckets =
          bucket_data
          |> Enum.filter(fn {{{_name, _labels}, bucket}, _value} ->
            is_number(bucket) or bucket == :infinity
          end)
          |> Enum.map(fn {{{_name, _labels}, bucket}, value} -> {bucket, value} end)
          |> Enum.sort()

        sum =
          bucket_data
          |> Enum.find(fn {{{_name, _labels}, bucket}, _value} -> bucket == :sum end)
          |> case do
            {_key, value} -> value
            nil -> 0.0
          end

        count =
          bucket_data
          |> Enum.find(fn {{{_name, _labels}, bucket}, _value} -> bucket == :count end)
          |> case do
            {_key, value} -> value
            nil -> 0
          end

        %{name: name, type: :histogram, labels: labels, buckets: buckets, sum: sum, count: count}
      end)

    counters ++ gauges ++ histograms
  end

  defp metric_help(name) do
    case name do
      "orchestrator_machine_starts_total" -> "Total number of machine starts"
      "orchestrator_machine_stops_total" -> "Total number of machine stops"
      "orchestrator_migrations_total" -> "Total number of migrations"
      "orchestrator_migration_duration_seconds" -> "Migration duration in seconds"
      "orchestrator_fsm_transitions_total" -> "Total FSM state transitions"
      "orchestrator_fsm_transition_duration_seconds" -> "FSM transition duration"
      "orchestrator_crdt_gossip_messages_total" -> "Total CRDT gossip messages sent"
      _ -> "Metric description"
    end
  end

  defp format_metric_line(%{type: :counter, name: name, labels: labels, value: value}) do
    "#{name}#{format_labels(labels)} #{value}\n"
  end

  defp format_metric_line(%{type: :gauge, name: name, labels: labels, value: value}) do
    "#{name}#{format_labels(labels)} #{value}\n"
  end

  defp format_metric_line(%{
         type: :histogram,
         name: name,
         labels: labels,
         buckets: buckets,
         sum: sum,
         count: count
       }) do
    bucket_map = Map.new(buckets)

    bucket_lines =
      @histogram_buckets
      |> Enum.map(fn bucket ->
        value = Map.get(bucket_map, bucket, 0)
        le = if bucket == :infinity, do: "+Inf", else: bucket
        "#{name}_bucket#{format_labels(Map.put(labels, :le, le))} #{value}\n"
      end)
      |> Enum.join("")

    sum_line = "#{name}_sum#{format_labels(labels)} #{sum}\n"
    count_line = "#{name}_count#{format_labels(labels)} #{count}\n"

    bucket_lines <> sum_line <> count_line
  end

  defp format_labels(labels) when labels == %{}, do: ""

  defp format_labels(labels) do
    label_pairs =
      Enum.map(labels, fn {key, value} ->
        "#{key}=\"#{value}\""
      end)
      |> Enum.join(",")

    "{#{label_pairs}}"
  end
end
