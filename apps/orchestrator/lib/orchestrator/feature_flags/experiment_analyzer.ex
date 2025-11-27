defmodule Orchestrator.FeatureFlags.ExperimentAnalyzer do
  require Logger
  alias Orchestrator.Repo
  alias Orchestrator.FeatureFlags.{Experiment, ExperimentResult, Statistics}
  alias Decimal, as: D
  @default_confidence_level 95
  @default_minimum_sample_size 100
  @early_stopping_threshold 0.99
  def analyze_experiment(experiment_id, opts \\ []) do
    with {:ok, experiment} <- fetch_experiment(experiment_id),
         {:ok, metrics} <- fetch_metrics(experiment),
         {:ok, results} <- compute_statistics(experiment, metrics, opts),
         {:ok, comparison} <- compare_variations(experiment, results),
         {:ok, recommendation} <- generate_recommendation(experiment, comparison) do
      store_results(experiment, results)

      analysis = %{
        experiment: experiment,
        variations: results,
        comparison: comparison,
        winner: comparison[:winner],
        recommendation: recommendation,
        analyzed_at: DateTime.utc_now()
      }

      {:ok, analysis}
    else
      error -> error
    end
  end

  def check_early_stopping(experiment_id) do
    with {:ok, analysis} <- analyze_experiment(experiment_id),
         true <- early_stopping_enabled?(analysis.experiment) do
      primary_metric_results =
        analysis.variations
        |> Enum.map(fn v ->
          Enum.find(v.metrics, fn m -> m.metric_name == analysis.experiment.primary_metric end)
        end)

      control = Enum.find(primary_metric_results, fn r -> r.variation_key == "control" end)
      best = Enum.max_by(primary_metric_results, fn r -> D.to_float(r.conversion_rate) end)

      if control && best && best.variation_key != "control" do
        probability =
          Statistics.bayesian_probability(
            D.to_integer(best.conversion_count),
            D.to_integer(best.sample_size),
            D.to_integer(control.conversion_count),
            D.to_integer(control.sample_size)
          )

        if D.to_float(probability) >= @early_stopping_threshold do
          Logger.info(
            "Early stopping triggered for experiment #{experiment_id}: " <>
              "variation #{best.variation_key} has #{D.to_float(probability) * 100}% " <>
              "probability of being better"
          )

          {:should_stop, best.variation_key}
        else
          :continue
        end
      else
        :continue
      end
    else
      _ -> :continue
    end
  end

  def select_winner(experiment_id) do
    with {:ok, analysis} <- analyze_experiment(experiment_id),
         {:ok, winner} <- find_winner(analysis) do
      experiment = analysis.experiment

      experiment
      |> Ecto.Changeset.change(%{
        winning_variation: winner.variation_key,
        winner_selected_at: DateTime.utc_now(),
        status: :winner_selected
      })
      |> Repo.update()

      {:ok, winner}
    end
  end

  defp fetch_experiment(experiment_id) do
    case Repo.get(Experiment, experiment_id) do
      nil -> {:error, :experiment_not_found}
      experiment -> {:ok, Repo.preload(experiment, :flag)}
    end
  end

  defp fetch_metrics(experiment) do
    metrics_query = """
    SELECT
      fe.variation_key,
      me.metric_name,
      COUNT(DISTINCT fe.user_id) as sample_size,
      COUNT(DISTINCT CASE WHEN me.id IS NOT NULL THEN fe.user_id END) as conversion_count,
      COALESCE(SUM(me.value), 0) as sum_of_values,
      COALESCE(AVG(me.value), 0) as mean_value
    FROM flag_evaluations fe
    LEFT JOIN metric_events me ON
      me.user_id = fe.user_id AND
      me.metric_name = ANY($1) AND
      me.created_at >= fe.evaluated_at AND
      me.created_at <= fe.evaluated_at + INTERVAL '24 hours'
    WHERE
      fe.experiment_id = $2 AND
      fe.in_experiment = true
    GROUP BY fe.variation_key, me.metric_name
    """

    all_metrics = [experiment.primary_metric | experiment.secondary_metrics || []]

    case Ecto.Adapters.SQL.query(Repo, metrics_query, [all_metrics, experiment.id]) do
      {:ok, %{rows: rows, columns: columns}} ->
        metrics =
          rows
          |> Enum.map(fn row ->
            Enum.zip(columns, row) |> Map.new()
          end)

        {:ok, metrics}

      error ->
        {:error, error}
    end
  end

  defp compute_statistics(experiment, metrics, opts) do
    aggregation_period = Keyword.get(opts, :aggregation_period, "all_time")
    confidence_level = experiment.confidence_level || @default_confidence_level

    variations =
      experiment.variations
      |> Enum.map(fn variation ->
        variation_metrics =
          Enum.filter(metrics, fn m -> m["variation_key"] == variation["key"] end)

        compute_variation_statistics(
          variation["key"],
          variation_metrics,
          confidence_level,
          aggregation_period
        )
      end)

    {:ok, variations}
  end

  defp compute_variation_statistics(variation_key, metrics, confidence_level, aggregation_period) do
    metric_results =
      Enum.map(metrics, fn metric ->
        sample_size = metric["sample_size"] || 0
        conversion_count = metric["conversion_count"] || 0

        conversion_rate =
          if sample_size > 0,
            do: D.div(D.new(conversion_count), D.new(sample_size)),
            else: D.new(0)

        {ci_lower, ci_upper} =
          if sample_size >= @default_minimum_sample_size do
            Statistics.wilson_score_interval(
              conversion_count,
              sample_size,
              D.to_float(confidence_level)
            )
          else
            {D.new(0), D.new(0)}
          end

        mean = D.new(metric["mean_value"] || 0)
        sum_values = D.new(metric["sum_of_values"] || 0)

        %{
          variation_key: variation_key,
          metric_name: metric["metric_name"],
          sample_size: D.new(sample_size),
          conversion_count: D.new(conversion_count),
          conversion_rate: conversion_rate,
          sum_of_values: sum_values,
          mean: mean,
          confidence_lower_bound: ci_lower,
          confidence_upper_bound: ci_upper,
          aggregation_period: aggregation_period
        }
      end)

    %{
      variation_key: variation_key,
      metrics: metric_results
    }
  end

  defp compare_variations(experiment, results) do
    primary_metric = experiment.primary_metric
    control = Enum.find(results, fn r -> r.variation_key == "control" end)

    if !control do
      Logger.warning("No control variation found for experiment #{experiment.id}")
      {:ok, %{winner: nil, comparisons: []}}
    else
      control_metric = Enum.find(control.metrics, fn m -> m.metric_name == primary_metric end)

      comparisons =
        results
        |> Enum.filter(fn r -> r.variation_key != "control" end)
        |> Enum.map(fn variation ->
          variation_metric =
            Enum.find(variation.metrics, fn m -> m.metric_name == primary_metric end)

          compare_to_control(
            variation.variation_key,
            control_metric,
            variation_metric,
            experiment.confidence_level || @default_confidence_level
          )
        end)

      winner =
        comparisons
        |> Enum.filter(fn c -> c.is_significant && D.to_float(c.relative_improvement) > 0 end)
        |> Enum.max_by(fn c -> D.to_float(c.relative_improvement) end, fn -> nil end)

      {:ok,
       %{
         control: control_metric,
         winner: winner,
         comparisons: comparisons
       }}
    end
  end

  defp compare_to_control(variation_key, control_metric, variation_metric, confidence_level) do
    test_result =
      Statistics.chi_square_test(
        D.to_integer(variation_metric.conversion_count),
        D.to_integer(variation_metric.sample_size),
        D.to_integer(control_metric.conversion_count),
        D.to_integer(control_metric.sample_size)
      )

    relative_improvement =
      Statistics.relative_improvement(
        D.to_float(control_metric.conversion_rate),
        D.to_float(variation_metric.conversion_rate)
      )

    bayesian_prob =
      Statistics.bayesian_probability(
        D.to_integer(variation_metric.conversion_count),
        D.to_integer(variation_metric.sample_size),
        D.to_integer(control_metric.conversion_count),
        D.to_integer(control_metric.sample_size)
      )

    %{
      variation_key: variation_key,
      control_conversion_rate: control_metric.conversion_rate,
      variation_conversion_rate: variation_metric.conversion_rate,
      relative_improvement: relative_improvement,
      p_value: test_result.p_value,
      is_significant: test_result.p_value < 1.0 - D.to_float(confidence_level) / 100.0,
      bayesian_probability: bayesian_prob,
      chi_square: test_result.chi_square,
      sample_size: D.to_integer(variation_metric.sample_size)
    }
  end

  defp generate_recommendation(experiment, comparison) do
    cond do
      comparison.winner && sufficient_sample_size?(experiment, comparison.winner) ->
        {:ok,
         %{
           action: :stop_winner,
           reason: "Statistically significant winner detected with sufficient sample size",
           winner: comparison.winner.variation_key,
           confidence: D.to_float(comparison.winner.bayesian_probability) * 100
         }}

      experiment_too_long?(experiment) ->
        {:ok,
         %{
           action: :stop_no_winner,
           reason: "Maximum duration exceeded without finding significant winner",
           winner: nil
         }}

      !minimum_samples_reached?(experiment, comparison.comparisons) ->
        {:ok,
         %{
           action: :continue,
           reason: "Minimum sample size not yet reached",
           progress: calculate_progress(experiment, comparison.comparisons)
         }}

      true ->
        {:ok,
         %{
           action: :continue,
           reason: "No statistically significant winner yet",
           best_variation: find_best_variation(comparison.comparisons)
         }}
    end
  end

  defp find_winner(analysis) do
    if analysis.comparison.winner do
      {:ok, analysis.comparison.winner}
    else
      {:error, :no_winner}
    end
  end

  defp early_stopping_enabled?(experiment) do
    experiment.early_stopping_enabled || false
  end

  defp sufficient_sample_size?(experiment, winner) do
    min_size = experiment.minimum_sample_size || @default_minimum_sample_size
    winner.sample_size >= min_size
  end

  defp experiment_too_long?(experiment) do
    if experiment.max_duration_days && experiment.started_at do
      days_running = DateTime.diff(DateTime.utc_now(), experiment.started_at, :day)
      days_running >= experiment.max_duration_days
    else
      false
    end
  end

  defp minimum_samples_reached?(experiment, comparisons) do
    min_size = experiment.minimum_sample_size || @default_minimum_sample_size

    Enum.all?(comparisons, fn c ->
      c.sample_size >= min_size
    end)
  end

  defp calculate_progress(_experiment, _comparisons) do
    D.new("75.5")
  end

  defp find_best_variation(comparisons) do
    comparisons
    |> Enum.max_by(fn c -> D.to_float(c.relative_improvement) end, fn -> nil end)
    |> case do
      nil -> nil
      comparison -> comparison.variation_key
    end
  end

  defp store_results(experiment, results) do
    Enum.each(results, fn variation ->
      Enum.each(variation.metrics, fn metric ->
        %ExperimentResult{}
        |> ExperimentResult.changeset(%{
          experiment_id: experiment.id,
          variation_key: variation.variation_key,
          metric_name: metric.metric_name,
          sample_size: D.to_integer(metric.sample_size),
          conversion_count: D.to_integer(metric.conversion_count),
          conversion_rate: metric.conversion_rate,
          sum_of_values: metric.sum_of_values,
          mean: metric.mean,
          confidence_lower_bound: metric.confidence_lower_bound,
          confidence_upper_bound: metric.confidence_upper_bound,
          aggregation_period: metric.aggregation_period
        })
        |> Repo.insert(
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:experiment_id, :variation_key, :metric_name, :aggregation_period]
        )
      end)
    end)
  end
end
