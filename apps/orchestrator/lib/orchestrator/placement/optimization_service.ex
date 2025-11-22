defmodule Orchestrator.Placement.OptimizationService do
  use GenServer
  require Logger
  alias Orchestrator.{Repo, Machine}
  alias Orchestrator.Placement.{CostOptimizer, LatencyOptimizer, Executor}
  alias Orchestrator.Events.Writer, as: EventWriter
  import Ecto.Query

  defstruct [
    :last_cost_optimization,
    :last_latency_optimization,
    :optimization_history,
    :config
  ]

  @type optimization_result :: %{
          type: :cost | :latency | :combined,
          analysis_duration_ms: non_neg_integer(),
          recommendations_count: non_neg_integer(),
          executed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          total_monthly_savings: Decimal.t(),
          average_latency_improvement_ms: float(),
          execution_mode: atom(),
          dry_run: boolean(),
          timestamp: DateTime.t()
        }
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec optimize_cost(keyword()) :: {:ok, optimization_result()} | {:error, any()}
  def optimize_cost(opts \\ []) do
    GenServer.call(__MODULE__, {:optimize_cost, opts}, 60_000)
  end

  @spec optimize_latency(keyword()) :: {:ok, optimization_result()} | {:error, any()}
  def optimize_latency(opts \\ []) do
    GenServer.call(__MODULE__, {:optimize_latency, opts}, 60_000)
  end

  @spec optimize_all(keyword()) :: {:ok, map()} | {:error, any()}
  def optimize_all(opts \\ []) do
    GenServer.call(__MODULE__, {:optimize_all, opts}, 120_000)
  end

  @spec get_optimization_history(keyword()) :: list(map())
  def get_optimization_history(opts \\ []) do
    GenServer.call(__MODULE__, {:get_history, opts})
  end

  @impl true
  def init(opts) do
    config = %{
      auto_execute: Keyword.get(opts, :auto_execute, false),
      cost_threshold: Keyword.get(opts, :cost_threshold, 100.00),
      latency_threshold: Keyword.get(opts, :latency_threshold, 50),
      schedule: Keyword.get(opts, :schedule)
    }

    state = %__MODULE__{
      last_cost_optimization: nil,
      last_latency_optimization: nil,
      optimization_history: [],
      config: config
    }

    Logger.info("OptimizationService started", config: config)
    {:ok, state}
  end

  @impl true
  def handle_call({:optimize_cost, opts}, _from, state) do
    Logger.info("Running cost optimization", opts: opts)
    start_time = System.monotonic_time(:millisecond)
    result = perform_cost_optimization(opts)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    new_state = %{
      state
      | last_cost_optimization: DateTime.utc_now(),
        optimization_history: add_to_history(state.optimization_history, result)
    }

    Logger.info("Cost optimization complete",
      duration_ms: duration_ms,
      success: match?({:ok, _}, result)
    )

    case result do
      {:ok, data} -> {:reply, {:ok, data}, new_state}
      error -> {:reply, error, new_state}
    end
  end

  @impl true
  def handle_call({:optimize_latency, opts}, _from, state) do
    Logger.info("Running latency optimization", opts: opts)
    start_time = System.monotonic_time(:millisecond)
    result = perform_latency_optimization(opts)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    new_state = %{
      state
      | last_latency_optimization: DateTime.utc_now(),
        optimization_history: add_to_history(state.optimization_history, result)
    }

    Logger.info("Latency optimization complete",
      duration_ms: duration_ms,
      success: match?({:ok, _}, result)
    )

    case result do
      {:ok, data} -> {:reply, {:ok, data}, new_state}
      error -> {:reply, error, new_state}
    end
  end

  @impl true
  def handle_call({:optimize_all, opts}, _from, state) do
    Logger.info("Running combined optimization", opts: opts)
    cost_weight = Keyword.get(opts, :cost_weight, 0.5)
    latency_weight = Keyword.get(opts, :latency_weight, 0.5)

    with {:ok, cost_result} <- perform_cost_optimization(Keyword.put(opts, :dry_run, true)),
         {:ok, latency_result} <- perform_latency_optimization(Keyword.put(opts, :dry_run, true)),
         {:ok, combined} <-
           combine_recommendations(cost_result, latency_result, cost_weight, latency_weight),
         {:ok, execution_result} <- execute_combined_recommendations(combined, opts) do
      result = %{
        type: :combined,
        cost_result: cost_result,
        latency_result: latency_result,
        combined_recommendations: combined,
        execution: execution_result,
        cost_weight: cost_weight,
        latency_weight: latency_weight,
        timestamp: DateTime.utc_now()
      }

      new_state = %{
        state
        | optimization_history: add_to_history(state.optimization_history, {:ok, result})
      }

      {:reply, {:ok, result}, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_history, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    history = Enum.take(state.optimization_history, limit)
    {:reply, history, state}
  end

  defp perform_cost_optimization(opts) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    min_savings = Keyword.get(opts, :min_monthly_savings, 0.00)
    max_recommendations = Keyword.get(opts, :max_recommendations)
    Logger.debug("Analyzing cost optimization opportunities")
    machines = load_machines_for_cost_analysis(opts)
    analysis_start = System.monotonic_time(:millisecond)
    cost_analysis = CostOptimizer.analyze_cost_savings(machines)
    analysis_duration = System.monotonic_time(:millisecond) - analysis_start

    filtered_recommendations =
      filter_cost_recommendations(
        cost_analysis.recommendations,
        min_savings
      )

    recommendations =
      if max_recommendations do
        Enum.take(filtered_recommendations, max_recommendations)
      else
        filtered_recommendations
      end

    Logger.info("Cost analysis complete",
      total_recommendations: length(recommendations),
      potential_savings: Decimal.to_string(cost_analysis.total_monthly_savings),
      analysis_duration_ms: analysis_duration
    )

    execution_result =
      if dry_run? || Enum.empty?(recommendations) do
        %{
          dry_run: true,
          executed_count: 0,
          failed_count: 0,
          actions: []
        }
      else
        case Executor.apply_cost_optimization(recommendations, opts) do
          {:ok, result} ->
            result

          {:error, reason} ->
            Logger.error("Cost optimization execution failed", reason: inspect(reason))
            %{success: false, error: reason}
        end
      end

    {:ok,
     %{
       type: :cost,
       analysis_duration_ms: analysis_duration,
       recommendations_count: length(recommendations),
       executed_count: execution_result[:executed_count] || 0,
       failed_count: execution_result[:failed_count] || 0,
       total_monthly_savings: cost_analysis.total_monthly_savings,
       average_latency_improvement_ms: 0.0,
       execution_mode: Keyword.get(opts, :mode, :progressive),
       dry_run: dry_run?,
       recommendations: recommendations,
       execution_result: execution_result,
       timestamp: DateTime.utc_now()
     }}
  end

  defp perform_latency_optimization(opts) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    min_improvement = Keyword.get(opts, :min_latency_improvement_ms, 0)
    max_migrations = Keyword.get(opts, :max_migrations)
    Logger.debug("Analyzing latency optimization opportunities")
    machines = load_machines_for_latency_analysis(opts)
    analysis_start = System.monotonic_time(:millisecond)
    latency_analysis = LatencyOptimizer.optimize_placements(machines)
    analysis_duration = System.monotonic_time(:millisecond) - analysis_start

    filtered_placements =
      filter_latency_placements(
        latency_analysis.improved_placements,
        min_improvement
      )

    placements =
      if max_migrations do
        Enum.take(filtered_placements, max_migrations)
      else
        filtered_placements
      end

    Logger.info("Latency analysis complete",
      total_placements: length(placements),
      avg_improvement_ms: latency_analysis.average_latency_improvement,
      analysis_duration_ms: analysis_duration
    )

    execution_result =
      if dry_run? || Enum.empty?(placements) do
        %{
          dry_run: true,
          executed_count: 0,
          failed_count: 0,
          actions: []
        }
      else
        case Executor.apply_latency_optimization(placements, opts) do
          {:ok, result} ->
            result

          {:error, reason} ->
            Logger.error("Latency optimization execution failed", reason: inspect(reason))
            %{success: false, error: reason}
        end
      end

    {:ok,
     %{
       type: :latency,
       analysis_duration_ms: analysis_duration,
       recommendations_count: length(placements),
       executed_count: execution_result[:executed_count] || 0,
       failed_count: execution_result[:failed_count] || 0,
       total_monthly_savings: Decimal.new(0),
       average_latency_improvement_ms: latency_analysis.average_latency_improvement,
       execution_mode: Keyword.get(opts, :mode, :progressive),
       dry_run: dry_run?,
       placements: placements,
       execution_result: execution_result,
       timestamp: DateTime.utc_now()
     }}
  end

  defp combine_recommendations(cost_result, latency_result, cost_weight, latency_weight) do
    Logger.info("Combining cost and latency recommendations",
      cost_weight: cost_weight,
      latency_weight: latency_weight
    )

    cost_scored = score_cost_recommendations(cost_result.recommendations, cost_weight)
    latency_scored = score_latency_placements(latency_result.placements, latency_weight)
    combined = merge_and_deduplicate(cost_scored, latency_scored)
    sorted = Enum.sort_by(combined, & &1.composite_score, :desc)
    {:ok, sorted}
  end

  defp score_cost_recommendations(recommendations, weight) do
    Enum.map(recommendations, fn rec ->
      savings_score = Decimal.to_float(rec[:monthly_savings] || Decimal.new(0)) / 10.0
      savings_score = min(savings_score, 100.0)

      Map.merge(rec, %{
        composite_score: savings_score * weight,
        optimization_type: :cost
      })
    end)
  end

  defp score_latency_placements(placements, weight) do
    Enum.map(placements, fn placement ->
      latency_score = (placement[:latency_improvement_ms] || 0) / 2.0
      latency_score = min(latency_score, 100.0)

      Map.merge(placement, %{
        composite_score: latency_score * weight,
        optimization_type: :latency
      })
    end)
  end

  defp merge_and_deduplicate(cost_recs, latency_recs) do
    all = cost_recs ++ latency_recs

    all
    |> Enum.group_by(& &1[:machine_id])
    |> Enum.map(fn {_machine_id, recs} ->
      Enum.max_by(recs, & &1.composite_score)
    end)
  end

  defp execute_combined_recommendations(combined, opts) do
    dry_run? = Keyword.get(opts, :dry_run, true)

    if dry_run? do
      {:ok, %{dry_run: true, executed_count: 0, simulated_count: length(combined)}}
    else
      {cost_recs, latency_recs} =
        Enum.split_with(combined, fn rec ->
          rec.optimization_type == :cost
        end)

      cost_result =
        if Enum.empty?(cost_recs) do
          {:ok, %{executed_count: 0}}
        else
          Executor.apply_cost_optimization(cost_recs, opts)
        end

      latency_result =
        if Enum.empty?(latency_recs) do
          {:ok, %{executed_count: 0}}
        else
          Executor.apply_latency_optimization(latency_recs, opts)
        end

      case {cost_result, latency_result} do
        {{:ok, cost_res}, {:ok, latency_res}} ->
          {:ok,
           %{
             cost_executed: cost_res.executed_count,
             latency_executed: latency_res.executed_count,
             total_executed: cost_res.executed_count + latency_res.executed_count,
             cost_failed: cost_res.failed_count,
             latency_failed: latency_res.failed_count
           }}

        {error, _} ->
          error

        {_, error} ->
          error
      end
    end
  end

  defp load_machines_for_cost_analysis(opts) do
    filters = Keyword.get(opts, :filters, %{})

    query =
      from(m in Machine,
        where: m.status in ["running", "stopped"],
        select: m
      )

    query = apply_filters(query, filters)
    Repo.all(query)
  end

  defp load_machines_for_latency_analysis(opts) do
    filters = Keyword.get(opts, :filters, %{})
    target_regions = Keyword.get(opts, :target_regions)

    query =
      from(m in Machine,
        where: m.status == "running",
        select: m
      )

    query = apply_filters(query, filters)
    machines = Repo.all(query)

    if target_regions do
      Enum.filter(machines, fn m -> m.region in target_regions end)
    else
      machines
    end
  end

  defp apply_filters(query, filters) when map_size(filters) == 0, do: query

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn {key, value}, q ->
      case key do
        :region -> from(m in q, where: m.region == ^value)
        :user_id -> from(m in q, where: m.user_id == ^value)
        _ -> q
      end
    end)
  end

  defp filter_cost_recommendations(recommendations, min_savings) do
    min_decimal = Decimal.new(to_string(min_savings))

    Enum.filter(recommendations, fn rec ->
      savings = rec[:monthly_savings] || Decimal.new(0)
      Decimal.compare(savings, min_decimal) != :lt
    end)
  end

  defp filter_latency_placements(placements, min_improvement) do
    Enum.filter(placements, fn placement ->
      improvement = placement[:latency_improvement_ms] || 0
      improvement >= min_improvement
    end)
  end

  defp add_to_history(history, {:ok, result}) do
    [result | Enum.take(history, 99)]
  end

  defp add_to_history(history, _error), do: history
end
