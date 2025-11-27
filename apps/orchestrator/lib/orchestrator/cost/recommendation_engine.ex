defmodule Orchestrator.Cost.RecommendationEngine do
  require Logger
  alias Orchestrator.{Repo, Machines}
  alias Orchestrator.Cost.RightsizingRecommendation
  import Ecto.Query
  @type machine_id :: String.t()
  @type region :: String.t()
  @type organization_id :: String.t()
  @type recommendation :: map()
  @type analysis_result :: {:ok, [recommendation()]} | {:error, term()}
  @analysis_period_days 7
  @min_data_points 168
  @cpu_downsize_threshold 40.0
  @cpu_upsize_threshold 80.0
  @memory_downsize_threshold 50.0
  @memory_upsize_threshold 85.0
  @idle_cpu_threshold 5.0
  @idle_memory_threshold 20.0

  @confidence_threshold 0.7
  @cost_savings_threshold 10.0
  @spec analyze_machine(machine_id()) :: analysis_result()
  def analyze_machine(machine_id) do
    with {:ok, machine} <- fetch_machine(machine_id),
         {:ok, usage_stats} <- calculate_usage_statistics(machine_id),
         {:ok, current_config} <- get_current_configuration(machine),
         {:ok, recommendation} <-
           generate_rightsizing_recommendation(machine, usage_stats, current_config) do
      {:ok, [recommendation]}
    end
  end

  @spec analyze_region(region()) :: analysis_result()
  def analyze_region(region) do
    machines =
      from(m in Machines.Machine,
        where: m.region == ^region and m.state == :running
      )
      |> Repo.all()

    recommendations =
      machines
      |> Enum.map(&analyze_machine(&1.id))
      |> Enum.filter(fn result -> match?({:ok, _}, result) end)
      |> Enum.flat_map(fn {:ok, recs} -> recs end)

    {:ok, recommendations}
  end

  @spec analyze_organization() :: {:ok, map()} | {:error, term()}
  def analyze_organization do
    with {:ok, rightsizing_recs} <- analyze_all_rightsizing(),
         {:ok, idle_resources} <- analyze_idle_resources(),
         {:ok, storage_recs} <- analyze_storage_optimization(),
         {:ok, cost_summary} <- calculate_cost_summary() do
      report = %{
        generated_at: DateTime.utc_now(),
        total_potential_savings:
          calculate_total_savings([
            rightsizing_recs,
            idle_resources,
            storage_recs
          ]),
        recommendations: %{
          rightsizing: rightsizing_recs,
          idle_resources: idle_resources,
          storage_optimization: storage_recs
        },
        cost_summary: cost_summary,
        top_opportunities:
          identify_top_opportunities([
            rightsizing_recs,
            idle_resources,
            storage_recs
          ])
      }

      {:ok, report}
    end
  end

  @spec forecast_costs(organization_id(), integer()) :: {:ok, map()} | {:error, term()}
  def forecast_costs(organization_id, days \\ 30) do
    with {:ok, historical_costs} <- fetch_historical_costs(organization_id, days * 2),
         {:ok, trend} <- calculate_cost_trend(historical_costs),
         {:ok, forecast} <- project_future_costs(trend, days) do
      result = %{
        organization_id: organization_id,
        forecast_period_days: days,
        historical_daily_average: calculate_average(historical_costs),
        projected_daily_average: forecast.daily_average,
        projected_total: forecast.total_cost,
        trend: trend.direction,
        trend_percentage: trend.percentage,
        confidence: forecast.confidence
      }

      {:ok, result}
    end
  end

  defp fetch_machine(machine_id) do
    case Repo.get(Machines.Machine, machine_id) do
      nil -> {:error, :machine_not_found}
      machine -> {:ok, machine}
    end
  end

  defp calculate_usage_statistics(machine_id) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-@analysis_period_days * 86400, :second)

    query = """
    SELECT
      COUNT(*) as data_points,
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY cpu_percent) as p50_cpu,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY cpu_percent) as p95_cpu,
      PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY cpu_percent) as p99_cpu,
      AVG(cpu_percent) as avg_cpu,
      MAX(cpu_percent) as max_cpu,
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY memory_mb) as p50_memory,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY memory_mb) as p95_memory,
      PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY memory_mb) as p99_memory,
      AVG(memory_mb) as avg_memory,
      MAX(memory_mb) as max_memory,
      AVG(storage_gb) as avg_storage,
      MAX(storage_gb) as max_storage,
      SUM(network_ingress_gb + network_egress_gb) as total_network_gb,
      AVG(request_count) as avg_requests
    FROM resource_usage
    WHERE machine_id = $1
      AND measured_at >= $2
    """

    case Repo.query(query, [machine_id, cutoff_date]) do
      {:ok, %{rows: [[data_points | stats]]}} when data_points >= @min_data_points ->
        [
          _,
          p50_cpu,
          p95_cpu,
          p99_cpu,
          avg_cpu,
          max_cpu,
          p50_memory,
          p95_memory,
          p99_memory,
          avg_memory,
          max_memory,
          avg_storage,
          max_storage,
          total_network,
          avg_requests
        ] = stats

        {:ok,
         %{
           data_points: data_points,
           cpu: %{
             p50: p50_cpu,
             p95: p95_cpu,
             p99: p99_cpu,
             avg: avg_cpu,
             max: max_cpu
           },
           memory: %{
             p50: p50_memory,
             p95: p95_memory,
             p99: p99_memory,
             avg: avg_memory,
             max: max_memory
           },
           storage: %{avg: avg_storage, max: max_storage},
           network_gb: total_network,
           avg_requests: avg_requests
         }}

      {:ok, %{rows: [[data_points | _]]}} ->
        {:error, {:insufficient_data, data_points, @min_data_points}}

      error ->
        Logger.error("Failed to calculate usage statistics: #{inspect(error)}")
        {:error, :query_failed}
    end
  end

  defp get_current_configuration(machine) do
    config = machine.config || %{}

    {:ok,
     %{
       cpu: Map.get(config, "cpu", 2),
       memory_mb: Map.get(config, "memory_mb", 4096),
       storage_gb: Map.get(config, "storage_gb", 50),
       instance_type: Map.get(config, "instance_type", "standard")
     }}
  end

  defp generate_rightsizing_recommendation(machine, usage_stats, current_config) do
    cpu_rec = analyze_cpu_sizing(usage_stats.cpu, current_config.cpu)
    memory_rec = analyze_memory_sizing(usage_stats.memory, current_config.memory_mb)
    storage_rec = analyze_storage_sizing(usage_stats.storage, current_config.storage_gb)
    has_recommendation = cpu_rec.action != :no_change || memory_rec.action != :no_change

    if has_recommendation do
      cost_impact =
        calculate_cost_impact(
          current_config,
          %{
            cpu: cpu_rec.recommended,
            memory_mb: memory_rec.recommended,
            storage_gb: storage_rec.recommended
          },
          machine.region
        )

      confidence = calculate_confidence(usage_stats, cpu_rec, memory_rec)
      risk = assess_risk(cpu_rec, memory_rec, confidence)

      if cost_impact.monthly_savings >= @cost_savings_threshold &&
           confidence >= @confidence_threshold do
        recommendation_params = %{
          machine_id: machine.id,
          region: machine.region,
          current_cpu: current_config.cpu,
          current_memory_mb: current_config.memory_mb,
          current_storage_gb: current_config.storage_gb,
          recommended_cpu: cpu_rec.recommended,
          recommended_memory_mb: memory_rec.recommended,
          recommended_storage_gb: storage_rec.recommended,
          cpu_p95_utilization: usage_stats.cpu.p95,
          memory_p95_utilization: usage_stats.memory.p95 / current_config.memory_mb * 100,
          current_monthly_cost: cost_impact.current_cost,
          recommended_monthly_cost: cost_impact.recommended_cost,
          monthly_savings: cost_impact.monthly_savings,
          annual_savings: Decimal.mult(cost_impact.monthly_savings, Decimal.new("12")),
          savings_percent: cost_impact.savings_percent,
          confidence_score: confidence,
          risk_level: risk,
          reason: generate_recommendation_reason(cpu_rec, memory_rec, usage_stats)
        }

        RightsizingRecommendation.generate(machine.id, recommendation_params)
      else
        {:ok, nil}
      end
    else
      {:ok, nil}
    end
  end

  defp analyze_cpu_sizing(%{p95: p95_cpu}, current_cpu) do
    cond do
      p95_cpu < @cpu_downsize_threshold ->
        recommended = max(1, ceil(p95_cpu * 1.2 / 100.0 * current_cpu))
        %{action: :downsize, current: current_cpu, recommended: recommended, utilization: p95_cpu}

      p95_cpu > @cpu_upsize_threshold ->
        recommended = ceil(current_cpu * 1.5)
        %{action: :upsize, current: current_cpu, recommended: recommended, utilization: p95_cpu}

      true ->
        %{
          action: :no_change,
          current: current_cpu,
          recommended: current_cpu,
          utilization: p95_cpu
        }
    end
  end

  defp analyze_memory_sizing(%{p95: p95_memory}, current_memory_mb) do
    p95_memory_percent = p95_memory / current_memory_mb * 100

    cond do
      p95_memory_percent < @memory_downsize_threshold ->
        recommended = max(1024, ceil(p95_memory * 1.25))

        %{
          action: :downsize,
          current: current_memory_mb,
          recommended: recommended,
          utilization: p95_memory_percent
        }

      p95_memory_percent > @memory_upsize_threshold ->
        recommended = ceil(current_memory_mb * 1.5)

        %{
          action: :upsize,
          current: current_memory_mb,
          recommended: recommended,
          utilization: p95_memory_percent
        }

      true ->
        %{
          action: :no_change,
          current: current_memory_mb,
          recommended: current_memory_mb,
          utilization: p95_memory_percent
        }
    end
  end

  defp analyze_storage_sizing(%{max: max_storage}, current_storage_gb) do
    used_percent = max_storage / current_storage_gb * 100

    if used_percent < 50 do
      recommended = max(10, ceil(max_storage * 1.3))

      %{
        action: :downsize,
        current: current_storage_gb,
        recommended: recommended,
        utilization: used_percent
      }
    else
      %{
        action: :no_change,
        current: current_storage_gb,
        recommended: current_storage_gb,
        utilization: used_percent
      }
    end
  end

  defp calculate_cost_impact(current_config, recommended_config, region) do
    pricing = get_region_pricing(region)

    current_cost = calculate_monthly_cost(current_config, pricing)
    recommended_cost = calculate_monthly_cost(recommended_config, pricing)

    monthly_savings = Decimal.sub(current_cost, recommended_cost)

    savings_percent =
      if Decimal.compare(current_cost, Decimal.new("0")) == :gt do
        Decimal.to_float(Decimal.div(monthly_savings, current_cost)) * 100
      else
        0.0
      end

    %{
      current_cost: current_cost,
      recommended_cost: recommended_cost,
      monthly_savings: monthly_savings,
      savings_percent: savings_percent
    }
  end

  defp get_region_pricing(_region) do
    %{
      cpu_per_core: Decimal.new("50.00"),
      memory_per_gb: Decimal.new("20.00"),
      storage_per_gb: Decimal.new("0.10")
    }
  end

  defp calculate_monthly_cost(config, pricing) do
    cpu_cost = Decimal.mult(Decimal.new(config.cpu), pricing.cpu_per_core)

    memory_gb = Decimal.div(Decimal.new(config.memory_mb), Decimal.new(1024))
    memory_cost = Decimal.mult(memory_gb, pricing.memory_per_gb)

    storage_cost = Decimal.mult(Decimal.new(config.storage_gb), pricing.storage_per_gb)

    Decimal.add(Decimal.add(cpu_cost, memory_cost), storage_cost)
  end

  defp calculate_confidence(usage_stats, cpu_rec, memory_rec) do
    data_point_score = min(1.0, usage_stats.data_points / (@min_data_points * 2))

    cpu_change_ratio =
      if usage_stats.avg_cpu > 0 do
        abs(cpu_rec.recommended - usage_stats.avg_cpu) / usage_stats.avg_cpu
      else
        0.0
      end

    memory_change_ratio =
      if usage_stats.avg_memory > 0 do
        abs(memory_rec.recommended - usage_stats.avg_memory) / usage_stats.avg_memory
      else
        0.0
      end

    volatility_penalty =
      if cpu_change_ratio > 2.0 or memory_change_ratio > 2.0 do
        0.2
      else
        0.0
      end

    cpu_variance =
      if usage_stats.avg_cpu > 0 do
        usage_stats.std_dev_cpu / usage_stats.avg_cpu
      else
        0.0
      end

    memory_variance =
      if usage_stats.avg_memory > 0 do
        usage_stats.std_dev_memory / usage_stats.avg_memory
      else
        0.0
      end

    cpu_variance_score = min(1.0, cpu_variance)
    memory_variance_score = min(1.0, memory_variance)

    base_score =
      data_point_score * 0.4 + (1.0 - cpu_variance_score) * 0.3 +
        (1.0 - memory_variance_score) * 0.3

    max(0.1, base_score - volatility_penalty)
    |> Float.round(2)
  end

  defp assess_risk(cpu_rec, memory_rec, confidence) do
    cond do
      cpu_rec.action == :upsize || memory_rec.action == :upsize || confidence < 0.6 ->
        "high"

      confidence < 0.8 ->
        "medium"

      true ->
        "low"
    end
  end

  defp generate_recommendation_reason(cpu_rec, memory_rec, usage_stats) do
    parts = []

    parts =
      if cpu_rec.action != :no_change do
        action = if cpu_rec.action == :downsize, do: "Low", else: "High"

        parts ++
          [
            "#{action} CPU utilization (P95: #{Float.round(cpu_rec.utilization, 2)}%)"
          ]
      else
        parts
      end

    parts =
      if memory_rec.action != :no_change do
        action = if memory_rec.action == :downsize, do: "Low", else: "High"

        parts ++
          [
            "#{action} memory utilization (P95: #{Float.round(memory_rec.utilization, 2)}%)"
          ]
      else
        parts
      end

    parts =
      parts ++
        [
          "Analyzed #{usage_stats.data_points} data points over #{@analysis_period_days} days"
        ]

    Enum.join(parts, ". ")
  end

  defp analyze_all_rightsizing do
    machines =
      from(m in Machines.Machine, where: m.state == :running)
      |> Repo.all()

    recommendations =
      machines
      |> Enum.map(&analyze_machine(&1.id))
      |> Enum.filter(fn
        {:ok, [rec]} when not is_nil(rec) -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, [rec]} -> rec end)

    {:ok, recommendations}
  end

  defp analyze_idle_resources do
    query = """
    SELECT machine_id, avg_cpu, avg_memory, idle_hours, last_request_at
    FROM detect_idle_resources($1, $2, $3)
    """

    case Repo.query(query, [24, @idle_cpu_threshold, @idle_memory_threshold]) do
      {:ok, result} ->
        idle_recs =
          Enum.map(result.rows, fn [machine_id, cpu, memory, hours, last_request] ->
            %{
              type: :idle_resource,
              machine_id: machine_id,
              avg_cpu: cpu,
              avg_memory: memory,
              idle_hours: hours,
              last_request_at: last_request,
              recommended_action: "shutdown",
              monthly_savings: Decimal.new("150.00")
            }
          end)

        {:ok, idle_recs}

      _ ->
        {:ok, []}
    end
  end

  defp analyze_storage_optimization do
    {:ok, []}
  end

  defp calculate_cost_summary do
    query = "SELECT * FROM mv_daily_cost_summary ORDER BY date DESC LIMIT 30"

    case Repo.query(query) do
      {:ok, result} ->
        summary = %{
          last_30_days_total: calculate_total_from_rows(result.rows),
          daily_average: calculate_average_from_rows(result.rows),
          trend: detect_cost_trend(result.rows)
        }

        {:ok, summary}

      _ ->
        {:ok, %{last_30_days_total: 0, daily_average: 0, trend: "stable"}}
    end
  end

  defp calculate_total_savings(recommendation_lists) do
    recommendation_lists
    |> List.flatten()
    |> Enum.reduce(Decimal.new("0"), fn rec, acc ->
      savings = Map.get(rec, :monthly_savings, Decimal.new("0"))
      Decimal.add(acc, savings)
    end)
  end

  defp identify_top_opportunities(recommendation_lists) do
    recommendation_lists
    |> List.flatten()
    |> Enum.sort_by(
      fn rec ->
        Decimal.to_float(Map.get(rec, :monthly_savings, Decimal.new("0")))
      end,
      :desc
    )
    |> Enum.take(10)
  end

  defp fetch_historical_costs(_organization_id, days) do
    query = """
    SELECT date, total_cost
    FROM mv_daily_cost_summary
    WHERE date >= CURRENT_DATE - INTERVAL '#{days} days'
    ORDER BY date ASC
    """

    case Repo.query(query) do
      {:ok, result} ->
        costs = Enum.map(result.rows, fn [date, cost] -> {date, cost} end)
        {:ok, costs}

      _ ->
        {:ok, []}
    end
  end

  defp calculate_cost_trend(historical_costs) do
    if length(historical_costs) < 7 do
      {:ok, %{direction: "stable", percentage: 0.0}}
    else
      {first_week, last_week} = split_into_weeks(historical_costs)
      first_avg = calculate_average(first_week)
      last_avg = calculate_average(last_week)
      percentage = (last_avg - first_avg) / first_avg * 100

      direction =
        cond do
          percentage > 5 -> "increasing"
          percentage < -5 -> "decreasing"
          true -> "stable"
        end

      {:ok, %{direction: direction, percentage: Float.round(percentage, 2)}}
    end
  end

  defp project_future_costs(trend, days) do
    daily_change_rate = trend.percentage / 100.0

    forecast = %{
      total_cost: Decimal.new("#{days * 100 * (1 + daily_change_rate)}"),
      daily_average: Decimal.new("#{100 * (1 + daily_change_rate)}"),
      confidence: 0.75
    }

    {:ok, forecast}
  end

  defp split_into_weeks(costs) do
    mid_point = div(length(costs), 2)
    {Enum.take(costs, mid_point), Enum.drop(costs, mid_point)}
  end

  defp calculate_average(costs) when is_list(costs) do
    if length(costs) > 0 do
      total = Enum.reduce(costs, 0, fn {_date, cost}, acc -> acc + cost end)
      total / length(costs)
    else
      0
    end
  end

  defp calculate_total_from_rows(rows) do
    Enum.reduce(rows, 0, fn row, acc -> acc + Enum.at(row, 1, 0) end)
  end

  defp calculate_average_from_rows(rows) do
    if length(rows) > 0 do
      calculate_total_from_rows(rows) / length(rows)
    else
      0
    end
  end

  defp detect_cost_trend(rows) do
    if length(rows) >= 7 do
      recent = Enum.take(rows, 7)
      older = Enum.take(rows, -7)
      recent_avg = calculate_average_from_rows(recent)
      older_avg = calculate_average_from_rows(older)
      change = (recent_avg - older_avg) / older_avg * 100

      cond do
        change > 5 -> "increasing"
        change < -5 -> "decreasing"
        true -> "stable"
      end
    else
      "insufficient_data"
    end
  end
end
