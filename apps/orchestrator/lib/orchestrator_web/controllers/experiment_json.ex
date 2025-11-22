defmodule OrchestratorWeb.ExperimentJSON do
  alias Orchestrator.FeatureFlags.Experiment

  def index(%{experiments: experiments}) do
    %{data: for(experiment <- experiments, do: data(experiment))}
  end

  def show(%{experiment: experiment}) do
    %{data: data(experiment)}
  end

  defp data(%Experiment{} = experiment) do
    %{
      id: experiment.id,
      key: experiment.key,
      name: experiment.name,
      description: experiment.description,
      hypothesis: experiment.hypothesis,
      status: experiment.status,
      flag: render_flag(experiment.flag),
      traffic_allocation: experiment.traffic_allocation,
      variations: experiment.variations,
      primary_metric: experiment.primary_metric,
      secondary_metrics: experiment.secondary_metrics,
      minimum_sample_size: experiment.minimum_sample_size,
      confidence_level: experiment.confidence_level,
      started_at: experiment.started_at,
      ended_at: experiment.ended_at,
      winning_variation: experiment.winning_variation,
      winner_selected_at: experiment.winner_selected_at,
      max_duration_days: experiment.max_duration_days,
      early_stopping_enabled: experiment.early_stopping_enabled,
      owner: experiment.owner,
      team: experiment.team,
      results: render_results(experiment.results),
      inserted_at: experiment.inserted_at,
      updated_at: experiment.updated_at
    }
  end

  defp render_flag(%Ecto.Association.NotLoaded{}), do: nil
  defp render_flag(nil), do: nil

  defp render_flag(flag) do
    %{
      id: flag.id,
      key: flag.key,
      name: flag.name
    }
  end

  defp render_results(%Ecto.Association.NotLoaded{}), do: nil
  defp render_results(nil), do: nil

  defp render_results(results) when is_list(results) do
    Enum.map(results, fn result ->
      %{
        variation_key: result.variation_key,
        metric_name: result.metric_name,
        sample_size: result.sample_size,
        conversion_count: result.conversion_count,
        conversion_rate: result.conversion_rate,
        mean: result.mean,
        confidence_interval: [
          result.confidence_lower_bound,
          result.confidence_upper_bound
        ],
        relative_improvement: result.relative_improvement,
        p_value: result.p_value,
        is_significant: result.is_significant
      }
    end)
  end
end
