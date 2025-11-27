defmodule OrchestratorWeb.ExperimentController do
  use OrchestratorWeb, :controller
  alias Orchestrator.FeatureFlags
  alias Orchestrator.FeatureFlags.Experiment
  alias Orchestrator.Repo

  action_fallback(OrchestratorWeb.FallbackController)

  def index(conn, params) do
    status = parse_status(params["status"])
    experiments = FeatureFlags.list_experiments(status)
    render(conn, :index, experiments: experiments)
  end

  def show(conn, %{"id" => id}) do
    case FeatureFlags.get_experiment(id) do
      nil -> {:error, :not_found}
      experiment -> render(conn, :show, experiment: experiment)
    end
  end

  def create(conn, %{"experiment" => experiment_params}) do
    with {:ok, %Experiment{} = experiment} <- FeatureFlags.create_experiment(experiment_params) do
      experiment = Repo.preload(experiment, :flag)

      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/experiments/#{experiment.id}")
      |> render(:show, experiment: experiment)
    end
  end

  def start(conn, %{"id" => id}) do
    with experiment when not is_nil(experiment) <- FeatureFlags.get_experiment(id),
         {:ok, %Experiment{} = updated} <- FeatureFlags.start_experiment(experiment) do
      render(conn, :show, experiment: updated)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def pause(conn, %{"id" => id}) do
    with experiment when not is_nil(experiment) <- FeatureFlags.get_experiment(id),
         {:ok, %Experiment{} = updated} <- FeatureFlags.pause_experiment(experiment) do
      render(conn, :show, experiment: updated)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def complete(conn, %{"id" => id}) do
    with experiment when not is_nil(experiment) <- FeatureFlags.get_experiment(id),
         {:ok, %Experiment{} = updated} <- FeatureFlags.complete_experiment(experiment) do
      render(conn, :show, experiment: updated)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def analysis(conn, %{"id" => id}) do
    case FeatureFlags.analyze_experiment(id) do
      {:ok, analysis} ->
        json(conn, %{
          experiment_id: id,
          analyzed_at: analysis.analyzed_at,
          variations: format_variations(analysis.variations),
          comparison: format_comparison(analysis.comparison),
          winner: analysis.winner,
          recommendation: analysis.recommendation
        })

      error ->
        error
    end
  end

  def check_early_stopping(conn, %{"id" => id}) do
    case FeatureFlags.check_early_stopping(id) do
      {:should_stop, winning_variation} ->
        json(conn, %{
          should_stop: true,
          winning_variation: winning_variation,
          reason: "Clear winner detected with high confidence"
        })

      :continue ->
        json(conn, %{
          should_stop: false,
          reason: "Continue collecting data"
        })
    end
  end

  def select_winner(conn, %{"id" => id}) do
    case FeatureFlags.select_winner(id) do
      {:ok, winner} ->
        json(conn, %{
          experiment_id: id,
          winner: winner,
          selected_at: DateTime.utc_now()
        })

      {:error, :no_winner} ->
        {:error, :bad_request, "No statistically significant winner found"}

      error ->
        error
    end
  end

  defp parse_status(nil), do: nil

  defp parse_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> nil
  end

  defp format_variations(variations) do
    Enum.map(variations, fn variation ->
      %{
        variation_key: variation.variation_key,
        metrics: Enum.map(variation.metrics, &format_metric/1)
      }
    end)
  end

  defp format_metric(metric) do
    %{
      metric_name: metric.metric_name,
      sample_size: metric.sample_size,
      conversion_count: metric.conversion_count,
      conversion_rate: metric.conversion_rate,
      confidence_interval: [
        metric.confidence_lower_bound,
        metric.confidence_upper_bound
      ]
    }
  end

  defp format_comparison(comparison) do
    %{
      control: format_control(comparison[:control]),
      comparisons: Enum.map(comparison[:comparisons] || [], &format_comparison_result/1)
    }
  end

  defp format_control(nil), do: nil

  defp format_control(control) do
    %{
      conversion_rate: control.conversion_rate,
      sample_size: control.sample_size
    }
  end

  defp format_comparison_result(result) do
    %{
      variation_key: result.variation_key,
      relative_improvement: result.relative_improvement,
      p_value: result.p_value,
      is_significant: result.is_significant,
      bayesian_probability: result.bayesian_probability
    }
  end
end
