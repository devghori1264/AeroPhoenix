defmodule Orchestrator.Scaling.AutoScaler do
  use GenServer
  require Logger
  alias Orchestrator.Repo
  alias Orchestrator.Scaling.{ScalingPolicy, ScalingEvent}
  alias Orchestrator.Metrics.{MetricSample, MetricDefinition}
  alias Orchestrator.Machines.Machine
  import Ecto.Query
  @type scaling_decision :: :scale_out | :scale_in | :no_change
  @type strategy :: :predictive | :reactive | :scheduled
  @default_evaluation_interval 60_000
  @default_prediction_window 300
  @default_confidence_threshold 0.8
  @min_training_samples 100
  @arima_order {1, 1, 1}
  @smoothing_alpha 0.3
  @trend_detection_threshold 0.1
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create_policy(map()) :: {:ok, ScalingPolicy.t()} | {:error, term()}
  def create_policy(attrs) do
    GenServer.call(__MODULE__, {:create_policy, attrs})
  end

  @spec update_policy(binary(), map()) :: {:ok, ScalingPolicy.t()} | {:error, term()}
  def update_policy(policy_id, attrs) do
    GenServer.call(__MODULE__, {:update_policy, policy_id, attrs})
  end

  @spec evaluate_scaling(String.t()) :: :ok
  def evaluate_scaling(service) do
    GenServer.cast(__MODULE__, {:evaluate_scaling, service})
  end

  @spec scale_now(String.t(), scaling_decision(), integer()) :: {:ok, map()} | {:error, term()}
  def scale_now(service, action, count) do
    GenServer.call(__MODULE__, {:scale_now, service, action, count})
  end

  @spec get_current_metrics(String.t()) :: {:ok, map()} | {:error, term()}
  def get_current_metrics(service) do
    GenServer.call(__MODULE__, {:get_current_metrics, service})
  end

  @spec get_scaling_history(String.t(), keyword()) :: list(ScalingEvent.t())
  def get_scaling_history(service, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    ScalingEvent.for_service(service, hours)
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
      prediction_window: Keyword.get(opts, :prediction_window, @default_prediction_window),
      confidence_threshold:
        Keyword.get(opts, :confidence_threshold, @default_confidence_threshold),
      models: %{},
      last_scale_time: %{},
      stats: %{
        evaluations: 0,
        scale_outs: 0,
        scale_ins: 0,
        prevented_by_cooldown: 0,
        ml_predictions: 0,
        prediction_accuracy: 0.0,
        errors: 0
      }
    }

    Logger.info("AutoScaler started with evaluation_interval=#{evaluation_interval}ms")
    {:ok, state}
  end

  @impl true
  def handle_call({:create_policy, attrs}, _from, state) do
    case ScalingPolicy.create(attrs) do
      {:ok, policy} ->
        {:reply, {:ok, policy}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:update_policy, policy_id, attrs}, _from, state) do
    case Repo.get(ScalingPolicy, policy_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      policy ->
        result = ScalingPolicy.update(policy, attrs)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:scale_now, service, action, count}, _from, state) do
    case execute_scaling(service, action, count, :manual) do
      {:ok, result} ->
        state = update_scaling_stats(state, action)
        {:reply, {:ok, result}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_current_metrics, service}, _from, state) do
    metrics = collect_current_metrics(service)
    {:reply, {:ok, metrics}, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_cast({:evaluate_scaling, service}, state) do
    state = evaluate_service_scaling(service, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:evaluate, state) do
    state = evaluate_all_services(state)
    schedule_evaluation(state.evaluation_interval)
    {:noreply, state}
  end

  defp evaluate_all_services(state) do
    policies = ScalingPolicy.list_enabled()
    state = update_in(state.stats.evaluations, &(&1 + 1))

    Enum.reduce(policies, state, fn policy, acc_state ->
      evaluate_service_scaling(policy.service, acc_state)
    end)
  end

  defp evaluate_service_scaling(service, state) do
    policy = ScalingPolicy.get_by_service(service)

    if policy && policy.enabled do
      current_metrics = collect_current_metrics(service)

      decision =
        case policy.strategy do
          "predictive" -> predictive_scaling_decision(service, policy, current_metrics, state)
          "reactive" -> reactive_scaling_decision(service, policy, current_metrics)
          "scheduled" -> scheduled_scaling_decision(service, policy, current_metrics)
          "hybrid" -> hybrid_scaling_decision(service, policy, current_metrics, state)
          _ -> {:no_change, 0, "Unknown strategy"}
        end

      case decision do
        {:scale_out, count, reason} ->
          execute_with_cooldown(service, :scale_out, count, reason, policy, state)

        {:scale_in, count, reason} ->
          execute_with_cooldown(service, :scale_in, count, reason, policy, state)

        {:no_change, _, _reason} ->
          state
      end
    else
      state
    end
  end

  defp predictive_scaling_decision(service, policy, current_metrics, state) do
    prediction = predict_future_load(service, policy.prediction_window, state)
    state = update_in(state.stats.ml_predictions, &(&1 + 1))

    cond do
      prediction.confidence >= state.confidence_threshold &&
          prediction.predicted_cpu > policy.target_cpu_percent * 1.2 ->
        count =
          calculate_scale_count(
            current_metrics.current_instances,
            prediction.predicted_cpu,
            policy.target_cpu_percent,
            policy.scale_out_increment
          )

        {:scale_out, count, "Predicted CPU: #{Float.round(prediction.predicted_cpu, 1)}%"}

      prediction.confidence >= state.confidence_threshold &&
        prediction.predicted_cpu < policy.target_cpu_percent * 0.5 &&
          current_metrics.current_instances > policy.min_instances ->
        {:scale_in, policy.scale_in_decrement,
         "Predicted low CPU: #{Float.round(prediction.predicted_cpu, 1)}%"}

      prediction.confidence < state.confidence_threshold ->
        reactive_scaling_decision(service, policy, current_metrics)

      true ->
        {:no_change, 0, "Within target range"}
    end
  end

  defp reactive_scaling_decision(service, policy, current_metrics) do
    cond do
      current_metrics.cpu_percent > policy.target_cpu_percent * 1.2 &&
          current_metrics.current_instances < policy.max_instances ->
        count =
          calculate_scale_count(
            current_metrics.current_instances,
            current_metrics.cpu_percent,
            policy.target_cpu_percent,
            policy.scale_out_increment
          )

        {:scale_out, count, "CPU: #{Float.round(current_metrics.cpu_percent, 1)}%"}

      current_metrics.memory_percent > policy.target_memory_percent * 1.2 &&
          current_metrics.current_instances < policy.max_instances ->
        {:scale_out, policy.scale_out_increment,
         "Memory: #{Float.round(current_metrics.memory_percent, 1)}%"}

      current_metrics.request_rate > 0 &&
        current_metrics.request_rate > current_metrics.avg_request_rate * 2.0 &&
          current_metrics.current_instances < policy.max_instances ->
        {:scale_out, policy.scale_out_increment,
         "Request rate spike: #{Float.round(current_metrics.request_rate, 0)}/s"}

      current_metrics.cpu_percent < policy.target_cpu_percent * 0.3 &&
        current_metrics.memory_percent < policy.target_memory_percent * 0.3 &&
          current_metrics.current_instances > policy.min_instances ->
        {:scale_in, policy.scale_in_decrement,
         "Low utilization: CPU #{Float.round(current_metrics.cpu_percent, 1)}%, MEM #{Float.round(current_metrics.memory_percent, 1)}%"}

      true ->
        {:no_change, 0, "Within target range"}
    end
  end

  defp scheduled_scaling_decision(service, policy, current_metrics) do
    now = DateTime.utc_now()
    hour = now.hour
    day_of_week = Date.day_of_week(DateTime.to_date(now))

    cond do
      day_of_week in 1..5 && hour >= 9 && hour < 17 &&
          current_metrics.current_instances < policy.min_instances * 2 ->
        {:scale_out, 1, "Business hours scaling"}

      (day_of_week in 6..7 || hour < 6 || hour >= 22) &&
          current_metrics.current_instances > policy.min_instances ->
        {:scale_in, 1, "Off-hours scaling"}

      true ->
        {:no_change, 0, "Schedule-based: no change needed"}
    end
  end

  defp hybrid_scaling_decision(service, policy, current_metrics, state) do
    predictive = predictive_scaling_decision(service, policy, current_metrics, state)
    reactive = reactive_scaling_decision(service, policy, current_metrics)

    case {predictive, reactive} do
      {{:scale_out, count1, reason1}, {:scale_out, count2, _}} ->
        {:scale_out, max(count1, count2), reason1}

      {{:scale_out, count, reason}, _} ->
        {:scale_out, count, reason}

      {_, {:scale_out, count, reason}} ->
        {:scale_out, count, reason}

      {{:scale_in, count, reason}, {:no_change, _, _}} ->
        {:scale_in, count, reason}

      _ ->
        {:no_change, 0, "Hybrid: no action needed"}
    end
  end

  defp predict_future_load(service, prediction_window_seconds, state) do
    historical_data = get_historical_metrics(service, hours: 168)

    if length(historical_data) >= @min_training_samples do
      time_series =
        Enum.map(historical_data, fn {_timestamp, metrics} ->
          metrics["cpu_percent"] || 0.0
        end)

      arima_pred = arima_forecast(time_series, prediction_window_seconds)
      ets_pred = exponential_smoothing_forecast(time_series)
      trend_pred = trend_analysis_forecast(time_series)
      predicted_cpu = arima_pred * 0.5 + ets_pred * 0.3 + trend_pred * 0.2
      confidence = calculate_prediction_confidence(historical_data, state)

      %{
        predicted_cpu: predicted_cpu,
        confidence: confidence,
        method: "ensemble",
        horizon_seconds: prediction_window_seconds
      }
    else
      %{
        predicted_cpu: 0.0,
        confidence: 0.0,
        method: "insufficient_data",
        horizon_seconds: prediction_window_seconds
      }
    end
  end

  defp arima_forecast(time_series, _horizon) do
    if length(time_series) < 3 do
      Enum.at(time_series, -1, 0.0)
    else
      recent = Enum.take(time_series, -10)
      avg = Enum.sum(recent) / length(recent)
      first_half = Enum.take(recent, div(length(recent), 2))
      second_half = Enum.drop(recent, div(length(recent), 2))

      trend =
        Enum.sum(second_half) / length(second_half) -
          Enum.sum(first_half) / length(first_half)

      max(0.0, min(100.0, avg + trend * 2))
    end
  end

  defp exponential_smoothing_forecast(time_series) do
    Enum.reduce(time_series, 0.0, fn value, forecast ->
      if forecast == 0.0 do
        value
      else
        @smoothing_alpha * value + (1 - @smoothing_alpha) * forecast
      end
    end)
  end

  defp trend_analysis_forecast(time_series) do
    n = length(time_series)

    if n < 2 do
      Enum.at(time_series, -1, 0.0)
    else
      recent = Enum.take(time_series, -div(n, 3)) |> Enum.sum() |> (&(&1 / max(1, div(n, 3)))).()
      older = Enum.take(time_series, div(n, 3)) |> Enum.sum() |> (&(&1 / max(1, div(n, 3)))).()
      trend_rate = (recent - older) / older

      if abs(trend_rate) > @trend_detection_threshold do
        max(0.0, min(100.0, recent * (1 + trend_rate)))
      else
        recent
      end
    end
  end

  defp calculate_prediction_confidence(historical_data, _state) do
    if length(historical_data) < @min_training_samples do
      0.0
    else
      cpu_values = Enum.map(historical_data, fn {_t, m} -> m["cpu_percent"] || 0.0 end)
      mean = Enum.sum(cpu_values) / length(cpu_values)

      variance =
        Enum.reduce(cpu_values, 0.0, fn val, acc ->
          acc + :math.pow(val - mean, 2)
        end) / length(cpu_values)

      std_dev = :math.sqrt(variance)
      confidence = max(0.0, min(1.0, 1.0 - std_dev / 50.0))
      confidence
    end
  end

  defp execute_with_cooldown(service, action, count, reason, policy, state) do
    last_scale = Map.get(state.last_scale_time, service)
    cooldown_seconds = get_cooldown_seconds(action, policy)

    if can_scale?(last_scale, cooldown_seconds) do
      case execute_scaling(service, action, count, reason) do
        {:ok, result} ->
          state
          |> put_in([Access.key!(:last_scale_time), service], DateTime.utc_now())
          |> update_scaling_stats(action)

        {:error, reason} ->
          Logger.error("Scaling failed for #{service}: #{inspect(reason)}")
          update_in(state.stats.errors, &(&1 + 1))
      end
    else
      elapsed =
        if last_scale do
          DateTime.diff(DateTime.utc_now(), last_scale)
        else
          cooldown_seconds + 1
        end

      Logger.debug(
        "Scaling prevented by cooldown for #{service} (elapsed: #{elapsed}s, required: #{cooldown_seconds}s)"
      )

      update_in(state.stats.prevented_by_cooldown, &(&1 + 1))
    end
  end

  defp can_scale?(nil, _cooldown), do: true

  defp can_scale?(last_scale_time, cooldown_seconds) do
    elapsed = DateTime.diff(DateTime.utc_now(), last_scale_time)
    elapsed >= cooldown_seconds
  end

  defp get_cooldown_seconds(:scale_out, policy), do: policy.scale_out_cooldown
  defp get_cooldown_seconds(:scale_in, policy), do: policy.scale_in_cooldown

  defp execute_scaling(service, :scale_out, count, reason) do
    Logger.info("SCALING OUT: #{service} +#{count} instances - #{reason}")
    current_machines = Machine.list_by_service(service, state: "running")
    current_count = length(current_machines)

    results =
      Enum.map(1..count, fn i ->
        Machine.create(%{
          service: service,
          state: "provisioning",
          region: select_optimal_region(service),
          instance_type: select_instance_type(service),
          created_by: "autoscaler"
        })
      end)

    successes = Enum.count(results, &match?({:ok, _}, &1))

    ScalingEvent.create(%{
      service: service,
      action: "scale_out",
      previous_count: current_count,
      new_count: current_count + successes,
      reason: reason,
      triggered_by: "autoscaler"
    })

    {:ok,
     %{
       action: :scale_out,
       previous_count: current_count,
       new_count: current_count + successes,
       added: successes
     }}
  end

  defp execute_scaling(service, :scale_in, count, reason) do
    Logger.info("SCALING IN: #{service} -#{count} instances - #{reason}")
    current_machines = Machine.list_by_service(service, state: "running")
    current_count = length(current_machines)

    machines_to_remove =
      current_machines
      |> sort_by_load()
      |> Enum.take(count)

    Enum.each(machines_to_remove, fn machine ->
      Machine.update(machine, %{state: "terminating"})
    end)

    removed = length(machines_to_remove)

    ScalingEvent.create(%{
      service: service,
      action: "scale_in",
      previous_count: current_count,
      new_count: current_count - removed,
      reason: reason,
      triggered_by: "autoscaler"
    })

    {:ok,
     %{
       action: :scale_in,
       previous_count: current_count,
       new_count: current_count - removed,
       removed: removed
     }}
  end

  defp collect_current_metrics(service) do
    machines = Machine.list_by_service(service, state: "running")
    current_count = length(machines)

    if current_count > 0 do
      cutoff = DateTime.utc_now() |> DateTime.add(-300, :second)
      cpu_metrics = get_service_metric(service, "cpu_usage_percent", cutoff)
      memory_metrics = get_service_metric(service, "memory_usage_percent", cutoff)
      request_metrics = get_service_metric(service, "request_rate", cutoff)
      avg_cpu = calculate_average(cpu_metrics)
      avg_memory = calculate_average(memory_metrics)
      current_request_rate = calculate_average(request_metrics)
      historical_cutoff = DateTime.utc_now() |> DateTime.add(-3600, :second)
      historical_requests = get_service_metric(service, "request_rate", historical_cutoff)
      avg_request_rate = calculate_average(historical_requests)

      %{
        current_instances: current_count,
        cpu_percent: avg_cpu,
        memory_percent: avg_memory,
        request_rate: current_request_rate,
        avg_request_rate: avg_request_rate,
        timestamp: DateTime.utc_now()
      }
    else
      %{
        current_instances: 0,
        cpu_percent: 0.0,
        memory_percent: 0.0,
        request_rate: 0.0,
        avg_request_rate: 0.0,
        timestamp: DateTime.utc_now()
      }
    end
  end

  defp get_service_metric(service, metric_name, since_time) do
    metric_def = MetricDefinition.get_by_name(metric_name)

    if metric_def do
      from(s in MetricSample,
        where: s.metric_id == ^metric_def.id,
        where: fragment("? @> ?::jsonb", s.labels, ^%{"service" => service}),
        where: s.timestamp >= ^since_time,
        select: s.value
      )
      |> Repo.all()
    else
      []
    end
  end

  defp get_historical_metrics(service, opts) do
    hours = Keyword.get(opts, :hours, 24)
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
    cpu_def = MetricDefinition.get_by_name("cpu_usage_percent")
    memory_def = MetricDefinition.get_by_name("memory_usage_percent")

    if cpu_def && memory_def do
      query = """
      SELECT
        time_bucket('1 hour', timestamp) as hour,
        AVG(CASE WHEN metric_id = $1 THEN value END) as cpu_percent,
        AVG(CASE WHEN metric_id = $2 THEN value END) as memory_percent
      FROM metric_samples
      WHERE timestamp >= $3
        AND labels @> $4::jsonb
      GROUP BY hour
      ORDER BY hour ASC
      """

      case Repo.query(query, [cpu_def.id, memory_def.id, cutoff, %{"service" => service}]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [timestamp, cpu, mem] ->
            {timestamp, %{"cpu_percent" => cpu || 0.0, "memory_percent" => mem || 0.0}}
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp calculate_average([]), do: 0.0

  defp calculate_average(values) do
    Enum.sum(values) / length(values)
  end

  defp calculate_scale_count(current_count, current_cpu, target_cpu, increment) do
    if target_cpu > 0 do
      needed_total = ceil(current_count * current_cpu / target_cpu)
      additional = max(increment, needed_total - current_count)
      min(additional, increment * 3)
    else
      increment
    end
  end

  defp select_optimal_region(_service) do
    "us-east-1"
  end

  defp select_instance_type(_service) do
    "t3.medium"
  end

  defp sort_by_load(machines) do
    Enum.shuffle(machines)
  end

  defp update_scaling_stats(state, :scale_out) do
    update_in(state.stats.scale_outs, &(&1 + 1))
  end

  defp update_scaling_stats(state, :scale_in) do
    update_in(state.stats.scale_ins, &(&1 + 1))
  end

  defp schedule_evaluation(interval) do
    Process.send_after(self(), :evaluate, interval)
  end
end
