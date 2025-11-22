defmodule Orchestrator.Metrics.AlertEngine do
  use GenServer
  require Logger
  alias Orchestrator.Repo

  alias Orchestrator.Metrics.{
    AlertRule,
    AlertInstance,
    MetricSample,
    MetricDefinition
  }

  import Ecto.Query
  @type notification_result :: {:ok, map()} | {:error, term()}
  @default_evaluation_interval 60_000
  @default_batch_size 50
  @default_notification_timeout 5000
  @default_re_notification_interval 3600
  @max_notification_retries 3
  @retry_backoff_ms 1000
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec evaluate_rule(binary()) :: :ok
  def evaluate_rule(rule_id) do
    GenServer.cast(__MODULE__, {:evaluate_rule, rule_id})
  end

  @spec evaluate_all() :: :ok
  def evaluate_all do
    GenServer.cast(__MODULE__, :evaluate_all)
  end

  @spec silence_alert(binary(), keyword()) :: {:ok, AlertInstance.t()} | {:error, term()}
  def silence_alert(instance_id, opts \\ []) do
    GenServer.call(__MODULE__, {:silence_alert, instance_id, opts})
  end

  @spec acknowledge_alert(binary(), String.t()) :: {:ok, AlertInstance.t()} | {:error, term()}
  def acknowledge_alert(instance_id, acknowledger) do
    GenServer.call(__MODULE__, {:acknowledge_alert, instance_id, acknowledger})
  end

  @spec resolve_alert(binary()) :: {:ok, AlertInstance.t()} | {:error, term()}
  def resolve_alert(instance_id) do
    GenServer.call(__MODULE__, {:resolve_alert, instance_id})
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def init(opts) do
    evaluation_interval = Keyword.get(opts, :evaluation_interval, @default_evaluation_interval)
    schedule_evaluation(evaluation_interval)

    state = %{
      evaluation_interval: evaluation_interval,
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      notification_timeout:
        Keyword.get(opts, :notification_timeout, @default_notification_timeout),
      re_notification_interval:
        Keyword.get(opts, :re_notification_interval, @default_re_notification_interval),
      stats: %{
        evaluations: 0,
        rules_evaluated: 0,
        alerts_fired: 0,
        alerts_resolved: 0,
        notifications_sent: 0,
        notification_failures: 0,
        evaluation_errors: 0,
        last_evaluation_duration_ms: 0
      }
    }

    Logger.info("AlertEngine started with evaluation_interval=#{evaluation_interval}ms")
    {:ok, state}
  end

  @impl true
  def handle_cast({:evaluate_rule, rule_id}, state) do
    case Repo.get(AlertRule, rule_id) do
      nil ->
        Logger.warning("Alert rule not found: #{rule_id}")
        {:noreply, state}

      rule ->
        state = evaluate_single_rule(rule, state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:evaluate_all, state) do
    state = evaluate_all_rules(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:silence_alert, instance_id, opts}, _from, state) do
    duration_minutes = Keyword.get(opts, :duration_minutes, 60)
    silenced_until = DateTime.utc_now() |> DateTime.add(duration_minutes * 60, :second)

    case Repo.get(AlertInstance, instance_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      instance ->
        result = AlertInstance.silence(instance, silenced_until)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:acknowledge_alert, instance_id, acknowledger}, _from, state) do
    case Repo.get(AlertInstance, instance_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      instance ->
        result = AlertInstance.acknowledge(instance, acknowledger)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:resolve_alert, instance_id}, _from, state) do
    case Repo.get(AlertInstance, instance_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      instance ->
        result = AlertInstance.resolve(instance)

        state =
          if elem(result, 0) == :ok do
            update_in(state.stats.alerts_resolved, &(&1 + 1))
          else
            state
          end

        {:reply, result, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_info(:evaluate, state) do
    start_time = System.monotonic_time()
    state = evaluate_all_rules(state)
    end_time = System.monotonic_time()
    duration_ms = System.convert_time_unit(end_time - start_time, :native, :millisecond)
    state = put_in(state.stats.last_evaluation_duration_ms, duration_ms)
    Logger.debug("Evaluated all rules in #{duration_ms}ms")
    schedule_evaluation(state.evaluation_interval)
    {:noreply, state}
  end

  defp evaluate_all_rules(state) do
    rules = AlertRule.due_for_evaluation()
    state = update_in(state.stats.evaluations, &(&1 + 1))

    if Enum.empty?(rules) do
      state
    else
      Logger.debug("Evaluating #{length(rules)} alert rules")

      rules
      |> Enum.chunk_every(state.batch_size)
      |> Enum.reduce(state, fn batch, acc_state ->
        batch
        |> Task.async_stream(&evaluate_single_rule(&1, acc_state),
          timeout: 30_000,
          max_concurrency: 10
        )
        |> Enum.reduce(acc_state, fn
          {:ok, new_state}, acc ->
            merge_stats(acc, new_state)

          {:exit, reason}, acc ->
            Logger.error("Rule evaluation failed: #{inspect(reason)}")
            update_in(acc.stats.evaluation_errors, &(&1 + 1))
        end)
      end)
    end
  end

  defp evaluate_single_rule(rule, state) do
    try do
      query_result = execute_query(rule.query, rule.label_matchers)
      AlertRule.update(rule, %{last_evaluated_at: DateTime.utc_now()})
      state = update_in(state.stats.rules_evaluated, &(&1 + 1))

      query_result
      |> Enum.reduce(state, fn {labels, value}, acc_state ->
        check_threshold_and_transition(rule, labels, value, acc_state)
      end)
    rescue
      error ->
        Logger.error("Error evaluating rule #{rule.name}: #{inspect(error)}")
        update_in(state.stats.evaluation_errors, &(&1 + 1))
    end
  end

  defp execute_query(query_string, label_matchers) do
    cond do
      String.contains?(query_string, "avg(") ->
        execute_aggregation_query(query_string, :avg, label_matchers)

      String.contains?(query_string, "max(") ->
        execute_aggregation_query(query_string, :max, label_matchers)

      String.contains?(query_string, "min(") ->
        execute_aggregation_query(query_string, :min, label_matchers)

      String.contains?(query_string, "rate(") ->
        execute_rate_query(query_string, label_matchers)

      String.contains?(query_string, "p95(") ->
        execute_percentile_query(query_string, 95, label_matchers)

      String.contains?(query_string, "p99(") ->
        execute_percentile_query(query_string, 99, label_matchers)

      true ->
        execute_simple_query(query_string, label_matchers)
    end
  end

  defp execute_aggregation_query(query_string, aggregation, label_matchers) do
    metric_name = extract_metric_name(query_string)
    time_range = extract_time_range(query_string)
    metric_def = MetricDefinition.get_by_name(metric_name)

    if metric_def do
      cutoff = DateTime.utc_now() |> DateTime.add(-parse_time_range(time_range), :second)

      query =
        from(s in MetricSample,
          where: s.metric_id == ^metric_def.id,
          where: s.timestamp >= ^cutoff,
          group_by: s.labels,
          select: {s.labels, fragment("?(?)", ^aggregation, s.value)}
        )

      query = apply_label_filters(query, label_matchers)
      Repo.all(query)
    else
      []
    end
  end

  defp execute_rate_query(query_string, label_matchers) do
    metric_name = extract_metric_name(query_string)
    time_range = extract_time_range(query_string)
    metric_def = MetricDefinition.get_by_name(metric_name)

    if metric_def do
      cutoff = DateTime.utc_now() |> DateTime.add(-parse_time_range(time_range), :second)

      query =
        from(s in MetricSample,
          where: s.metric_id == ^metric_def.id,
          where: s.timestamp >= ^cutoff,
          group_by: s.labels,
          select: {
            s.labels,
            fragment(
              "(MAX(value) - MIN(value)) / EXTRACT(EPOCH FROM (MAX(timestamp) - MIN(timestamp)))"
            )
          }
        )

      query = apply_label_filters(query, label_matchers)
      Repo.all(query)
    else
      []
    end
  end

  defp execute_percentile_query(query_string, percentile, label_matchers) do
    metric_name = extract_metric_name(query_string)
    time_range = extract_time_range(query_string)
    metric_def = MetricDefinition.get_by_name(metric_name)

    if metric_def do
      cutoff = DateTime.utc_now() |> DateTime.add(-parse_time_range(time_range), :second)

      query =
        from(s in MetricSample,
          where: s.metric_id == ^metric_def.id,
          where: s.timestamp >= ^cutoff,
          group_by: s.labels,
          select: {
            s.labels,
            fragment("percentile_cont(?) WITHIN GROUP (ORDER BY value)", ^(percentile / 100.0))
          }
        )

      query = apply_label_filters(query, label_matchers)
      Repo.all(query)
    else
      []
    end
  end

  defp execute_simple_query(query_string, label_matchers) do
    metric_name = String.trim(query_string)
    metric_def = MetricDefinition.get_by_name(metric_name)

    if metric_def do
      query =
        from(s in MetricSample,
          where: s.metric_id == ^metric_def.id,
          where: s.timestamp >= ago(5, "minute"),
          distinct: s.labels,
          order_by: [desc: s.timestamp],
          select: {s.labels, s.value}
        )

      query = apply_label_filters(query, label_matchers)
      Repo.all(query)
    else
      []
    end
  end

  defp apply_label_filters(query, nil), do: query
  defp apply_label_filters(query, label_matchers) when label_matchers == %{}, do: query

  defp apply_label_filters(query, label_matchers) do
    Enum.reduce(label_matchers, query, fn {key, value}, acc_query ->
      from(s in acc_query,
        where: fragment("? @> ?::jsonb", s.labels, ^%{key => value})
      )
    end)
  end

  defp extract_metric_name(query_string) do
    query_string
    |> String.replace(~r/^(avg|max|min|rate|p95|p99)\(/, "")
    |> String.replace(~r/\{.*?\}.*$/, "")
    |> String.replace(~r/\[.*?\].*$/, "")
    |> String.replace(")", "")
    |> String.trim()
  end

  defp extract_time_range(query_string) do
    case Regex.run(~r/\[(\d+[smhd])\]/, query_string) do
      [_, range] -> range
      _ -> "5m"
    end
  end

  defp parse_time_range(range_str) do
    case Regex.run(~r/^(\d+)([smhd])$/, range_str) do
      [_, value, unit] ->
        value = String.to_integer(value)

        case unit do
          "s" -> value
          "m" -> value * 60
          "h" -> value * 3600
          "d" -> value * 86400
        end

      _ ->
        300
    end
  end

  defp check_threshold_and_transition(rule, labels, value, state) do
    threshold_met = evaluate_condition(value, rule.condition, rule.threshold)
    existing_instance = find_alert_instance(rule.id, labels)

    cond do
      threshold_met and is_nil(existing_instance) ->
        create_pending_alert(rule, labels, value, state)

      threshold_met and existing_instance.state == "pending" ->
        check_duration_and_fire(rule, existing_instance, value, state)

      threshold_met and existing_instance.state == "firing" ->
        update_firing_alert(existing_instance, value, state)

      threshold_met and existing_instance.state == "resolved" ->
        reopen_alert(rule, existing_instance, value, state)

      not threshold_met and not is_nil(existing_instance) and
          existing_instance.state in ["firing", "pending"] ->
        resolve_firing_alert(existing_instance, state)

      true ->
        state
    end
  end

  defp evaluate_condition(value, condition, threshold) do
    case condition do
      ">" -> value > threshold
      ">=" -> value >= threshold
      "<" -> value < threshold
      "<=" -> value <= threshold
      "==" -> value == threshold
      "!=" -> value != threshold
      _ -> false
    end
  end

  defp find_alert_instance(rule_id, labels) do
    from(i in AlertInstance,
      where: i.alert_rule_id == ^rule_id,
      where: i.labels == ^labels,
      where: i.state in ["pending", "firing", "resolved"],
      order_by: [desc: i.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp create_pending_alert(rule, labels, value, state) do
    {:ok, _instance} =
      AlertInstance.create(%{
        alert_rule_id: rule.id,
        state: "pending",
        severity: rule.severity,
        labels: labels,
        current_value: value,
        threshold: rule.threshold,
        started_at: DateTime.utc_now()
      })

    Logger.info(
      "Created pending alert for rule '#{rule.name}' (value: #{value}, threshold: #{rule.threshold})"
    )

    state
  end

  defp check_duration_and_fire(rule, instance, value, state) do
    elapsed = DateTime.diff(DateTime.utc_now(), instance.started_at)

    if elapsed >= rule.duration_seconds do
      {:ok, fired_instance} = AlertInstance.fire(instance, value)
      Logger.warning("Alert FIRED: #{rule.name} (value: #{value}, threshold: #{rule.threshold})")
      state = send_notifications(rule, fired_instance, state)
      AlertRule.update(rule, %{last_state: "firing"})
      update_in(state.stats.alerts_fired, &(&1 + 1))
    else
      state
    end
  end

  defp update_firing_alert(instance, value, state) do
    AlertInstance.update(instance, %{current_value: value})

    if should_re_notify?(instance, state.re_notification_interval) do
      rule = Repo.get!(AlertRule, instance.alert_rule_id)
      send_notifications(rule, instance, state)
    else
      state
    end
  end

  defp reopen_alert(rule, instance, value, state) do
    AlertInstance.update(instance, %{
      state: "pending",
      current_value: value,
      started_at: DateTime.utc_now(),
      resolved_at: nil
    })

    Logger.info("Alert reopened: #{rule.name}")
    state
  end

  defp resolve_firing_alert(instance, state) do
    {:ok, _resolved} = AlertInstance.resolve(instance)
    rule = Repo.get!(AlertRule, instance.alert_rule_id)
    Logger.info("Alert RESOLVED: #{rule.name}")
    AlertRule.update(rule, %{last_state: "resolved"})
    state = send_resolution_notification(rule, instance, state)
    update_in(state.stats.alerts_resolved, &(&1 + 1))
  end

  defp should_re_notify?(instance, re_notification_interval) do
    case instance.notified_at do
      nil ->
        true

      last_notified ->
        elapsed = DateTime.diff(DateTime.utc_now(), last_notified, :second)
        elapsed >= re_notification_interval
    end
  end

  defp send_notifications(rule, instance, state) do
    channels = rule.notification_channels || []

    if Enum.empty?(channels) do
      state
    else
      message = build_alert_message(rule, instance, :firing)

      results =
        Enum.map(channels, fn channel ->
          send_notification(channel, message, state.notification_timeout)
        end)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, _}, &1))

      if successes > 0 do
        AlertInstance.record_notification(instance)
      end

      state
      |> update_in([Access.key!(:stats), :notifications_sent], &(&1 + successes))
      |> update_in([Access.key!(:stats), :notification_failures], &(&1 + failures))
    end
  end

  defp send_resolution_notification(rule, instance, state) do
    channels = rule.notification_channels || []

    if Enum.empty?(channels) do
      state
    else
      message = build_alert_message(rule, instance, :resolved)

      results =
        Enum.map(channels, fn channel ->
          send_notification(channel, message, state.notification_timeout)
        end)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, _}, &1))

      state
      |> update_in([Access.key!(:stats), :notifications_sent], &(&1 + successes))
      |> update_in([Access.key!(:stats), :notification_failures], &(&1 + failures))
    end
  end

  defp send_notification(channel, message, timeout) do
    case channel do
      "email" -> send_email_notification(message, timeout)
      "slack" -> send_slack_notification(message, timeout)
      "pagerduty" -> send_pagerduty_notification(message, timeout)
      "webhook" -> send_webhook_notification(message, timeout)
      "sms" -> send_sms_notification(message, timeout)
      _ -> {:error, :unknown_channel}
    end
  end

  defp send_email_notification(message, _timeout) do
    Logger.info("EMAIL notification: #{message.subject}")
    {:ok, %{channel: "email", sent_at: DateTime.utc_now()}}
  end

  defp send_slack_notification(message, timeout) do
    Logger.info("SLACK notification: #{message.title}")
    {:ok, %{channel: "slack", sent_at: DateTime.utc_now()}}
  end

  defp send_pagerduty_notification(message, timeout) do
    Logger.info("PAGERDUTY notification: #{message.title}")
    {:ok, %{channel: "pagerduty", sent_at: DateTime.utc_now()}}
  end

  defp send_webhook_notification(message, timeout) do
    Logger.info("WEBHOOK notification: #{message.title}")
    {:ok, %{channel: "webhook", sent_at: DateTime.utc_now()}}
  end

  defp send_sms_notification(message, timeout) do
    Logger.info("SMS notification: #{message.title}")
    {:ok, %{channel: "sms", sent_at: DateTime.utc_now()}}
  end

  defp build_alert_message(rule, instance, status) do
    %{
      title: "[#{String.upcase(to_string(instance.severity))}] #{rule.name}",
      subject: build_subject(rule, instance, status),
      body: build_body(rule, instance, status),
      severity: instance.severity,
      status: status,
      labels: instance.labels,
      current_value: instance.current_value,
      threshold: instance.threshold,
      started_at: instance.started_at,
      rule_id: rule.id,
      instance_id: instance.id
    }
  end

  defp build_subject(rule, instance, :firing) do
    "Alert: #{rule.name} - Current: #{format_value(instance.current_value)}, Threshold: #{format_value(instance.threshold)}"
  end

  defp build_subject(rule, _instance, :resolved) do
    "Resolved: #{rule.name}"
  end

  defp build_body(rule, instance, :firing) do
    """
    Alert: #{rule.name}
    Severity: #{instance.severity}
    Status: FIRING
    Current Value: #{format_value(instance.current_value)}
    Threshold: #{rule.condition} #{format_value(instance.threshold)}
    Duration: #{rule.duration_seconds}s
    Labels: #{format_labels(instance.labels)}
    Started At: #{DateTime.to_iso8601(instance.started_at)}
    """
  end

  defp build_body(rule, instance, :resolved) do
    duration =
      if instance.resolved_at && instance.started_at do
        DateTime.diff(instance.resolved_at, instance.started_at)
      else
        0
      end

    """
    Alert: #{rule.name}
    Status: RESOLVED
    Duration: #{format_duration(duration)}
    Labels: #{format_labels(instance.labels)}
    Resolved At: #{DateTime.to_iso8601(instance.resolved_at || DateTime.utc_now())}
    """
  end

  defp format_value(value) when is_float(value), do: Float.round(value, 2)
  defp format_value(value), do: value
  defp format_labels(labels) when labels == %{}, do: "none"

  defp format_labels(labels) do
    labels
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(", ")
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{Float.round(seconds / 3600, 1)}h"

  defp merge_stats(state1, state2) do
    update_in(state1.stats, fn stats ->
      Map.merge(stats, state2.stats, fn
        _key, v1, v2 when is_number(v1) and is_number(v2) -> v1 + v2
        _key, v1, _v2 -> v1
      end)
    end)
  end

  defp schedule_evaluation(interval) do
    Process.send_after(self(), :evaluate, interval)
  end
end
