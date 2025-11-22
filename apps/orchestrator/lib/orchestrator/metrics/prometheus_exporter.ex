defmodule Orchestrator.Metrics.PrometheusExporter do
  require Logger
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.{MetricDefinition, MetricSample}
  import Ecto.Query
  @spec export(list(String.t()) | :all, keyword()) :: String.t()
  def export(metric_names \\ :all, opts \\ []) do
    time_window = calculate_time_window(opts)

    metrics =
      case metric_names do
        :all -> MetricDefinition.list_enabled()
        names -> load_metrics_by_names(names)
      end

    metrics
    |> Enum.map(&export_metric(&1, time_window))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> then(&(&1 <> "\n"))
  end

  @spec export_metric(MetricDefinition.t(), DateTime.t()) :: String.t() | nil
  def export_metric(metric, since_time) do
    samples = get_recent_samples(metric.id, since_time)

    if Enum.empty?(samples) do
      nil
    else
      lines = [
        format_help(metric),
        format_type(metric),
        format_samples(metric, samples)
      ]

      Enum.join(lines, "\n")
    end
  end

  defp calculate_time_window(opts) do
    cond do
      hours = Keyword.get(opts, :hours) ->
        DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

      minutes = Keyword.get(opts, :minutes) ->
        DateTime.utc_now() |> DateTime.add(-minutes * 60, :second)

      true ->
        DateTime.utc_now() |> DateTime.add(-3600, :second)
    end
  end

  defp load_metrics_by_names(names) do
    from(m in MetricDefinition,
      where: m.name in ^names and m.enabled == true
    )
    |> Repo.all()
  end

  defp get_recent_samples(metric_id, since_time) do
    from(s in MetricSample,
      where: s.metric_id == ^metric_id,
      where: s.timestamp >= ^since_time,
      order_by: [desc: s.timestamp]
    )
    |> Repo.all()
  end

  defp format_help(metric) do
    help_text = metric.help || "Metric: #{metric.name}"
    "# HELP #{sanitize_name(metric.name)} #{escape_help(help_text)}"
  end

  defp format_type(metric) do
    "# TYPE #{sanitize_name(metric.name)} #{metric.type}"
  end

  defp format_samples(metric, samples) do
    case metric.type do
      "counter" -> format_counter_samples(metric, samples)
      "gauge" -> format_gauge_samples(metric, samples)
      "histogram" -> format_histogram_samples(metric, samples)
      "summary" -> format_summary_samples(metric, samples)
      _ -> ""
    end
  end

  defp format_counter_samples(metric, samples) do
    samples
    |> Enum.group_by(& &1.labels)
    |> Enum.map(fn {labels, grouped_samples} ->
      total_value = Enum.reduce(grouped_samples, 0.0, fn s, acc -> acc + (s.value || 0) end)
      latest_sample = Enum.max_by(grouped_samples, & &1.timestamp)

      format_metric_line(
        metric.name,
        labels,
        total_value,
        latest_sample.timestamp
      )
    end)
    |> Enum.join("\n")
  end

  defp format_gauge_samples(metric, samples) do
    samples
    |> Enum.group_by(& &1.labels)
    |> Enum.map(fn {labels, grouped_samples} ->
      latest = Enum.max_by(grouped_samples, & &1.timestamp)

      format_metric_line(
        metric.name,
        labels,
        latest.value,
        latest.timestamp
      )
    end)
    |> Enum.join("\n")
  end

  defp format_histogram_samples(metric, samples) do
    samples
    |> Enum.group_by(& &1.labels)
    |> Enum.flat_map(fn {labels, grouped_samples} ->
      latest = Enum.max_by(grouped_samples, & &1.timestamp)
      bucket_values = latest.bucket_values || []
      count = latest.count || 0
      sum = latest.sum || 0.0

      bucket_lines =
        Enum.map(bucket_values, fn bucket ->
          le_label = Map.put(labels, "le", to_string(bucket["le"]))

          format_metric_line(
            "#{metric.name}_bucket",
            le_label,
            bucket["count"],
            latest.timestamp
          )
        end)

      inf_label = Map.put(labels, "le", "+Inf")

      inf_line =
        format_metric_line(
          "#{metric.name}_bucket",
          inf_label,
          count,
          latest.timestamp
        )

      sum_line = format_metric_line("#{metric.name}_sum", labels, sum, latest.timestamp)
      count_line = format_metric_line("#{metric.name}_count", labels, count, latest.timestamp)
      bucket_lines ++ [inf_line, sum_line, count_line]
    end)
    |> Enum.join("\n")
  end

  defp format_summary_samples(metric, samples) do
    samples
    |> Enum.group_by(& &1.labels)
    |> Enum.flat_map(fn {labels, grouped_samples} ->
      latest = Enum.max_by(grouped_samples, & &1.timestamp)
      quantile_values = latest.quantile_values || []
      count = latest.count || 0
      sum = latest.sum || 0.0

      quantile_lines =
        Enum.map(quantile_values, fn quantile ->
          quantile_label = Map.put(labels, "quantile", to_string(quantile["quantile"]))

          format_metric_line(
            metric.name,
            quantile_label,
            quantile["value"],
            latest.timestamp
          )
        end)

      sum_line = format_metric_line("#{metric.name}_sum", labels, sum, latest.timestamp)
      count_line = format_metric_line("#{metric.name}_count", labels, count, latest.timestamp)
      quantile_lines ++ [sum_line, count_line]
    end)
    |> Enum.join("\n")
  end

  defp format_metric_line(name, labels, value, timestamp) do
    labels_str = format_labels(labels)
    timestamp_ms = DateTime.to_unix(timestamp, :millisecond)
    "#{sanitize_name(name)}#{labels_str} #{format_value(value)} #{timestamp_ms}"
  end

  defp format_labels(labels) when labels == %{} or labels == nil, do: ""

  defp format_labels(labels) do
    labels_str =
      labels
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {k, v} -> "#{k}=\"#{escape_label_value(v)}\"" end)
      |> Enum.join(",")

    "{#{labels_str}}"
  end

  defp format_value(value) when is_float(value) do
    cond do
      value == 0.0 -> "0"
      abs(value) < 0.000001 -> Float.to_string(value)
      abs(value) > 1_000_000 -> Float.to_string(value)
      true -> :erlang.float_to_binary(value, [:compact, decimals: 6])
    end
  end

  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value), do: to_string(value)

  defp sanitize_name(name) do
    String.replace(name, ".", "_")
  end

  defp escape_help(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
  end

  defp escape_label_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp escape_label_value(value), do: to_string(value)
end
