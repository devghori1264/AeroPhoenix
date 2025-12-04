defmodule OrchestratorWeb.PlacementController do
  use OrchestratorWeb, :controller
  require Logger
  alias Orchestrator.Placement.{LatencyOptimizer, CostOptimizer}
  alias Orchestrator.{Repo, Machines.Machine}

  def optimize(conn, params) do
    machine_spec = params["machine_spec"] || %{}
    mode = params["optimization_mode"] || "balanced"
    constraints = params["constraints"] || %{}
    affinity_rules = params["affinity_rules"] || []
    anti_affinity_rules = params["anti_affinity_rules"] || []

    case mode do
      "latency" ->
        optimize_for_latency(conn, machine_spec, constraints, affinity_rules, anti_affinity_rules)

      "cost" ->
        optimize_for_cost(conn, machine_spec, constraints)

      "balanced" ->
        optimize_balanced(conn, machine_spec, constraints, affinity_rules, anti_affinity_rules)

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid optimization_mode. Must be 'latency', 'cost', or 'balanced'"})
    end
  end

  def evaluate(conn, %{"machine_id" => machine_id}) do
    case Repo.get(Machine, machine_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Machine not found"})

      machine ->
        {:ok, latency_eval} = LatencyOptimizer.evaluate_placement(machine)
        cost_eval = evaluate_cost_efficiency(machine)

        evaluation = %{
          machine_id: machine_id,
          region: machine.region,
          latency_optimization: latency_eval,
          cost_efficiency: cost_eval,
          overall_score: calculate_overall_score(latency_eval, cost_eval),
          recommendations: latency_eval.recommendations ++ cost_eval.recommendations
        }

        json(conn, evaluation)
    end
  end

  def consolidations(conn, params) do
    min_savings = params["min_savings_percent"] || 10.0

    case CostOptimizer.recommend_consolidations(min_savings_percent: min_savings) do
      {:ok, recommendations} ->
        response = %{
          total_recommendations: length(recommendations),
          total_potential_savings:
            Enum.sum(Enum.map(recommendations, & &1.estimated_savings_usd)),
          recommendations: recommendations
        }

        json(conn, response)
    end
  end

  def rightsizing(conn, params) do
    lookback_days = params["lookback_days"] || 7

    case CostOptimizer.recommend_rightsizing(lookback_days: lookback_days) do
      {:ok, recommendations} ->
        response = %{
          total_recommendations: length(recommendations),
          total_potential_savings:
            Enum.sum(Enum.map(recommendations, & &1.potential_savings_usd)),
          recommendations: recommendations
        }

        json(conn, response)
    end
  end

  def cost_analysis(conn, _params) do
    case CostOptimizer.calculate_total_cost() do
      {:ok, analysis} ->
        json(conn, analysis)
    end
  end

  def enforce_budget(conn, params) do
    budget_limit = params["budget_limit"]
    period = String.to_atom(params["period"] || "monthly")

    if is_nil(budget_limit) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "budget_limit is required"})
    else
      case CostOptimizer.enforce_budget(budget_limit, period) do
        {:within_budget, status} ->
          json(conn, Map.put(status, :status, "within_budget"))

        {:over_budget, status} ->
          conn
          |> put_status(:payment_required)
          |> json(Map.put(status, :status, "over_budget"))
      end
    end
  end

  defp optimize_for_latency(conn, machine_spec, constraints, affinity_rules, anti_affinity_rules) do
    options = [
      mode: :simulated_annealing,
      max_latency_ms: constraints["max_latency_ms"],
      allowed_regions: constraints["allowed_regions"],
      affinity_rules: parse_affinity_rules(affinity_rules),
      anti_affinity_rules: parse_affinity_rules(anti_affinity_rules),
      latency_weight: 0.6,
      affinity_weight: 0.3,
      distribution_weight: 0.1
    ]

    case LatencyOptimizer.find_optimal_placement(machine_spec, options) do
      {:ok, region, score} ->
        json(conn, %{
          optimization_mode: "latency",
          recommended_region: region,
          score: score,
          placement_quality: "optimal"
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  defp optimize_for_cost(conn, machine_spec, constraints) do
    options = [
      algorithm: :best_fit,
      budget_limit: constraints["budget_limit"],
      prefer_consolidation: true,
      allow_spot: true
    ]

    case CostOptimizer.find_cost_optimal_placement(machine_spec, options) do
      {:ok, placement} ->
        json(conn, %{
          optimization_mode: "cost",
          recommended_host: placement.host.id,
          region: placement.host.region,
          estimated_cost_per_hour: placement.estimated_cost_per_hour,
          algorithm: placement.algorithm,
          placement_quality: "optimal"
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  defp optimize_balanced(conn, machine_spec, constraints, affinity_rules, anti_affinity_rules) do
    latency_options = [
      mode: :greedy,
      max_latency_ms: constraints["max_latency_ms"],
      affinity_rules: parse_affinity_rules(affinity_rules),
      anti_affinity_rules: parse_affinity_rules(anti_affinity_rules),
      latency_weight: 0.4,
      affinity_weight: 0.3,
      distribution_weight: 0.3
    ]

    cost_options = [
      algorithm: :best_fit,
      budget_limit: constraints["budget_limit"],
      prefer_consolidation: false
    ]

    with {:ok, latency_region, latency_score} <-
           LatencyOptimizer.find_optimal_placement(machine_spec, latency_options),
         {:ok, cost_placement} <-
           CostOptimizer.find_cost_optimal_placement(machine_spec, cost_options) do
      combined_score = calculate_balanced_score(latency_score, cost_placement)

      recommendation =
        if combined_score.latency_score > combined_score.cost_score do
          %{
            recommended_region: latency_region,
            primary_optimization: "latency",
            estimated_cost_per_hour: estimate_cost_for_region(machine_spec, latency_region)
          }
        else
          %{
            recommended_region: cost_placement.host.region,
            recommended_host: cost_placement.host.id,
            primary_optimization: "cost",
            estimated_cost_per_hour: cost_placement.estimated_cost_per_hour
          }
        end

      json(
        conn,
        Map.merge(recommendation, %{
          optimization_mode: "balanced",
          combined_score: combined_score,
          placement_quality: "optimal"
        })
      )
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  defp parse_affinity_rules(rules) when is_list(rules) do
    Enum.map(rules, fn rule ->
      {rule["machine_id"], rule["strength"] || 1.0}
    end)
  end

  defp parse_affinity_rules(_), do: []

  defp evaluate_cost_efficiency(_machine) do
    %{
      current_cost_per_hour: 5.0,
      optimal_cost_per_hour: 4.0,
      efficiency_score: 0.8,
      recommendations: ["Consider right-sizing to reduce costs"]
    }
  end

  defp calculate_overall_score(latency_eval, cost_eval) do
    (latency_eval.total_score + cost_eval.efficiency_score) / 2.0
  end

  defp calculate_balanced_score(latency_score, cost_placement) do
    %{
      latency_score: latency_score.total,
      cost_score: 1.0 - cost_placement.estimated_cost_per_hour / 10.0,
      combined:
        (latency_score.total + (1.0 - cost_placement.estimated_cost_per_hour / 10.0)) / 2.0
    }
  end

  defp estimate_cost_for_region(_machine_spec, _region) do
    5.0
  end
end
