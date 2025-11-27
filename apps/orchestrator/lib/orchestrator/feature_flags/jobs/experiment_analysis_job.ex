defmodule Orchestrator.FeatureFlags.Jobs.ExperimentAnalysisJob do
  use Oban.Worker,
    queue: :experiments,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  require Logger
  alias Orchestrator.FeatureFlags
  alias Orchestrator.FeatureFlags.ExperimentAnalyzer
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"experiment_id" => experiment_id}}) do
    Logger.info("Running analysis for experiment: #{experiment_id}")

    with {:ok, analysis} <- ExperimentAnalyzer.analyze_experiment(experiment_id),
         :ok <- check_and_handle_early_stopping(experiment_id, analysis),
         :ok <- broadcast_analysis_results(experiment_id, analysis) do
      Logger.info("Completed analysis for experiment: #{experiment_id}")
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to analyze experiment #{experiment_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def schedule_all do
    experiments = FeatureFlags.list_experiments(:running)
    Logger.info("Scheduling analysis for #{length(experiments)} running experiments")

    Enum.each(experiments, fn experiment ->
      %{experiment_id: experiment.id}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    {:ok, length(experiments)}
  end

  defp check_and_handle_early_stopping(experiment_id, analysis) do
    experiment = analysis.experiment

    if experiment.early_stopping_enabled do
      case ExperimentAnalyzer.check_early_stopping(experiment_id) do
        {:should_stop, winning_variation} ->
          Logger.info(
            "Early stopping triggered for experiment #{experiment_id}, winner: #{winning_variation}"
          )

          case FeatureFlags.select_winner(experiment_id) do
            {:ok, _winner} ->
              Logger.info("Winner automatically selected for experiment #{experiment_id}")
              :ok

            error ->
              Logger.error("Failed to select winner: #{inspect(error)}")
              :ok
          end

        :continue ->
          :ok
      end
    else
      :ok
    end
  end

  defp broadcast_analysis_results(experiment_id, analysis) do
    Phoenix.PubSub.broadcast(
      Orchestrator.PubSub,
      "experiment:#{experiment_id}:analysis",
      %{
        event: "analysis_updated",
        experiment_id: experiment_id,
        recommendation: analysis.recommendation,
        winner: analysis.winner,
        timestamp: DateTime.utc_now()
      }
    )

    :ok
  end
end
