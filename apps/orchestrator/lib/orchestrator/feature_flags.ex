defmodule Orchestrator.FeatureFlags do
  import Ecto.Query
  alias Orchestrator.Repo

  alias Orchestrator.FeatureFlags.{
    Flag,
    TargetingRule,
    Override,
    Experiment,
    Engine,
    ExperimentAnalyzer
  }

  def create_flag(attrs) do
    %Flag{}
    |> Flag.changeset(attrs)
    |> Repo.insert()
  end

  def update_flag(%Flag{} = flag, attrs) do
    new_version = %Flag{
      version: (flag.version || 1) + 1,
      previous_version_id: flag.id
    }

    new_version
    |> Flag.changeset(Map.merge(Map.from_struct(flag), attrs))
    |> Repo.insert()
  end

  def delete_flag(%Flag{} = flag) do
    flag
    |> Flag.changeset(%{status: :archived})
    |> Repo.update()
  end

  def get_flag(id) do
    Repo.get(Flag, id)
  end

  def get_flag_by_key(key) do
    Repo.get_by(Flag, key: key, status: :active)
  end

  def list_flags(opts \\ []) do
    Flag
    |> filter_by_team(opts[:team])
    |> filter_by_owner(opts[:owner])
    |> filter_by_tags(opts[:tags])
    |> filter_by_status(opts[:status] || :active)
    |> Repo.all()
  end

  def evaluate(flag_key, context) when is_binary(flag_key) and is_map(context) do
    Engine.evaluate(flag_key, context)
  end

  def evaluate_batch(flag_keys, context) when is_list(flag_keys) do
    flag_keys
    |> Enum.map(fn key ->
      case evaluate(key, context) do
        {:ok, value} -> {key, value}
      end
    end)
    |> Map.new()
  end

  def create_targeting_rule(flag_id, attrs) do
    attrs = Map.put(attrs, :flag_id, flag_id)

    %TargetingRule{}
    |> TargetingRule.changeset(attrs)
    |> Repo.insert()
  end

  def update_targeting_rule(%TargetingRule{} = rule, attrs) do
    rule
    |> TargetingRule.changeset(attrs)
    |> Repo.update()
  end

  def delete_targeting_rule(%TargetingRule{} = rule) do
    Repo.delete(rule)
  end

  def list_targeting_rules(flag_id) do
    TargetingRule
    |> where([r], r.flag_id == ^flag_id)
    |> order_by([r], asc: r.priority)
    |> Repo.all()
  end

  def create_override(attrs) do
    %Override{}
    |> Override.changeset(attrs)
    |> Repo.insert()
  end

  def delete_override(%Override{} = override) do
    Repo.delete(override)
  end

  def get_override(flag_key, user_id: user_id) do
    Override
    |> where([o], o.flag_key == ^flag_key and o.user_id == ^user_id)
    |> where([o], o.enabled == true)
    |> where([o], is_nil(o.expires_at) or o.expires_at > ^DateTime.utc_now())
    |> Repo.one()
  end

  def get_override(flag_key, machine_id: machine_id) do
    Override
    |> where([o], o.flag_key == ^flag_key and o.machine_id == ^machine_id)
    |> where([o], o.enabled == true)
    |> where([o], is_nil(o.expires_at) or o.expires_at > ^DateTime.utc_now())
    |> Repo.one()
  end

  def create_experiment(attrs) do
    %Experiment{}
    |> Experiment.changeset(attrs)
    |> Repo.insert()
  end

  def start_experiment(%Experiment{} = experiment) do
    experiment
    |> Experiment.changeset(%{
      status: :running,
      started_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def pause_experiment(%Experiment{} = experiment) do
    experiment
    |> Experiment.changeset(%{status: :paused})
    |> Repo.update()
  end

  def complete_experiment(%Experiment{} = experiment) do
    experiment
    |> Experiment.changeset(%{
      status: :completed,
      ended_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def get_experiment(id) do
    Experiment
    |> Repo.get(id)
    |> Repo.preload([:flag, :results])
  end

  def list_experiments(status \\ nil) do
    Experiment
    |> filter_experiment_status(status)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
    |> Repo.preload(:flag)
  end

  def analyze_experiment(experiment_id, opts \\ []) do
    ExperimentAnalyzer.analyze_experiment(experiment_id, opts)
  end

  def check_early_stopping(experiment_id) do
    ExperimentAnalyzer.check_early_stopping(experiment_id)
  end

  def select_winner(experiment_id) do
    ExperimentAnalyzer.select_winner(experiment_id)
  end

  def track_metric(user_id, metric_name, value \\ 1.0) do
    query = """
    INSERT INTO metric_events (id, user_id, metric_name, value, created_at)
    VALUES ($1, $2, $3, $4, $5)
    """

    Ecto.Adapters.SQL.query(
      Repo,
      query,
      [
        Ecto.UUID.generate(),
        user_id,
        metric_name,
        Decimal.new(value),
        DateTime.utc_now()
      ]
    )
  end

  def get_flag_statistics(flag_key, _period \\ :last_7_days) do
    query = """
    SELECT * FROM flag_statistics
    WHERE flag_key = $1
    ORDER BY date DESC
    LIMIT 7
    """

    case Ecto.Adapters.SQL.query(Repo, query, [flag_key]) do
      {:ok, %{rows: rows, columns: columns}} ->
        stats =
          rows
          |> Enum.map(fn row -> Enum.zip(columns, row) |> Map.new() end)

        {:ok, stats}

      error ->
        error
    end
  end

  defp filter_by_team(query, nil), do: query

  defp filter_by_team(query, team) do
    where(query, [f], f.team == ^team)
  end

  defp filter_by_owner(query, nil), do: query

  defp filter_by_owner(query, owner) do
    where(query, [f], f.owner == ^owner)
  end

  defp filter_by_tags(query, nil), do: query

  defp filter_by_tags(query, tags) when is_list(tags) do
    where(query, [f], fragment("? && ?", f.tags, ^tags))
  end

  defp filter_by_status(query, status) do
    where(query, [f], f.status == ^status)
  end

  defp filter_experiment_status(query, nil), do: query

  defp filter_experiment_status(query, status) do
    where(query, [e], e.status == ^status)
  end
end
