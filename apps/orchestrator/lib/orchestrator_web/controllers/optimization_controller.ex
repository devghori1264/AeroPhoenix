defmodule OrchestratorWeb.OptimizationController do
  use OrchestratorWeb, :controller
  require Logger
  alias Orchestrator.Placement.{OptimizationService, Executor}

  def optimize_cost(conn, params) do
    opts = parse_optimization_params(params)
    Logger.info("Cost optimization requested", opts: opts)

    case OptimizationService.optimize_cost(opts) do
      {:ok, result} ->
        json(conn, %{
          success: true,
          data: serialize_optimization_result(result)
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          success: false,
          error: inspect(reason)
        })
    end
  end

  def optimize_latency(conn, params) do
    opts = parse_optimization_params(params)
    Logger.info("Latency optimization requested", opts: opts)

    case OptimizationService.optimize_latency(opts) do
      {:ok, result} ->
        json(conn, %{
          success: true,
          data: serialize_optimization_result(result)
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          success: false,
          error: inspect(reason)
        })
    end
  end

  def optimize_combined(conn, params) do
    opts = parse_combined_params(params)
    Logger.info("Combined optimization requested", opts: opts)

    case OptimizationService.optimize_all(opts) do
      {:ok, result} ->
        json(conn, %{
          success: true,
          data: serialize_combined_result(result)
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          success: false,
          error: inspect(reason)
        })
    end
  end

  def get_history(conn, params) do
    limit = Map.get(params, "limit", "20") |> String.to_integer()
    history = OptimizationService.get_optimization_history(limit: limit)

    json(conn, %{
      success: true,
      data: %{
        history: Enum.map(history, &serialize_history_entry/1),
        count: length(history)
      }
    })
  end

  def execute_placement(conn, params) do
    recommendation = parse_recommendation(params)
    opts = parse_execution_opts(params)

    Logger.info("Executing placement",
      type: recommendation[:type],
      machine_id: recommendation[:machine_id]
    )

    case Executor.execute_placement(recommendation, opts) do
      {:ok, result} ->
        json(conn, %{
          success: true,
          data: result
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          success: false,
          error: inspect(reason)
        })
    end
  end

  def rollback_execution(conn, %{"execution_id" => execution_id} = params) do
    opts = parse_rollback_opts(params)
    Logger.warn("Rollback requested", execution_id: execution_id)

    case Executor.rollback_execution(execution_id, opts) do
      {:ok, result} ->
        json(conn, %{
          success: true,
          data: result
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          success: false,
          error: inspect(reason)
        })
    end
  end

  defp parse_optimization_params(params) do
    []
    |> put_if_present(:dry_run, params["dry_run"])
    |> put_if_present(:mode, parse_mode(params["mode"]))
    |> put_if_present(:min_monthly_savings, params["min_monthly_savings"])
    |> put_if_present(:min_latency_improvement_ms, params["min_latency_improvement_ms"])
    |> put_if_present(:max_recommendations, params["max_recommendations"])
    |> put_if_present(:max_migrations, params["max_migrations"])
    |> put_if_present(:max_concurrent, params["max_concurrent"])
    |> put_if_present(:timeout, params["timeout_ms"])
    |> put_if_present(:rate_limit, params["rate_limit"])
    |> put_if_present(:filters, params["filters"])
    |> put_if_present(:target_regions, params["target_regions"])
  end

  defp parse_combined_params(params) do
    []
    |> put_if_present(:cost_weight, params["cost_weight"])
    |> put_if_present(:latency_weight, params["latency_weight"])
    |> put_if_present(:mode, parse_mode(params["mode"]))
    |> put_if_present(:dry_run, params["dry_run"])
    |> put_if_present(:max_concurrent, params["max_concurrent"])
  end

  defp parse_recommendation(params) do
    %{
      type: parse_action_type(params["type"]),
      machine_id: params["machine_id"]
    }
    |> put_if_present(:target_region, params["target_region"])
    |> put_if_present(:target_host, params["target_host"])
    |> put_if_present(:strategy, params["strategy"])
    |> put_if_present(:current_specs, params["current_specs"])
    |> put_if_present(:target_specs, params["target_specs"])
    |> put_if_present(:machines_to_move, params["machines_to_move"])
    |> put_if_present(:host_id, params["host_id"])
  end

  defp parse_execution_opts(params) do
    []
    |> put_if_present(:validate, params["validate"])
    |> put_if_present(:create_checkpoint, params["create_checkpoint"])
    |> put_if_present(:force, params["force"])
    |> put_if_present(:timeout, params["timeout_ms"])
  end

  defp parse_rollback_opts(params) do
    []
    |> put_if_present(:checkpoint_id, params["checkpoint_id"])
  end

  defp parse_mode(nil), do: nil
  defp parse_mode("dry_run"), do: :dry_run
  defp parse_mode("progressive"), do: :progressive
  defp parse_mode("atomic"), do: :atomic
  defp parse_mode("staged"), do: :staged
  defp parse_mode(mode) when is_atom(mode), do: mode
  defp parse_mode(_), do: :progressive
  defp parse_action_type(nil), do: nil
  defp parse_action_type("migrate"), do: :migrate
  defp parse_action_type("rightsize"), do: :rightsize
  defp parse_action_type("consolidate"), do: :consolidate
  defp parse_action_type("decommission"), do: :decommission
  defp parse_action_type(type) when is_atom(type), do: type
  defp parse_action_type(_), do: :migrate
  defp put_if_present(list_or_map, _key, nil), do: list_or_map

  defp put_if_present(list, key, value) when is_list(list) do
    Keyword.put(list, key, value)
  end

  defp put_if_present(map, key, value) when is_map(map) do
    Map.put(map, key, value)
  end

  defp serialize_optimization_result(result) do
    %{
      type: result.type,
      analysis_duration_ms: result.analysis_duration_ms,
      recommendations_count: result.recommendations_count,
      executed_count: result.executed_count,
      failed_count: result.failed_count,
      total_monthly_savings: Decimal.to_string(result.total_monthly_savings),
      average_latency_improvement_ms: result.average_latency_improvement_ms,
      execution_mode: result.execution_mode,
      dry_run: result.dry_run,
      timestamp: DateTime.to_iso8601(result.timestamp),
      recommendations: result[:recommendations] || result[:placements] || [],
      execution_result: result[:execution_result]
    }
  end

  defp serialize_combined_result(result) do
    %{
      type: result.type,
      cost_weight: result.cost_weight,
      latency_weight: result.latency_weight,
      cost_result: serialize_optimization_result(result.cost_result),
      latency_result: serialize_optimization_result(result.latency_result),
      combined_recommendations_count: length(result.combined_recommendations),
      combined_recommendations: Enum.take(result.combined_recommendations, 20),
      execution: result.execution,
      timestamp: DateTime.to_iso8601(result.timestamp)
    }
  end

  defp serialize_history_entry(entry) do
    case entry.type do
      :combined -> serialize_combined_result(entry)
      _ -> serialize_optimization_result(entry)
    end
  end
end
