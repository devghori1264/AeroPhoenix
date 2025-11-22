defmodule Orchestrator.Metrics.AnomalyModel do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.{MetricDefinition, Anomaly}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @algorithms ~w(z_score iqr isolation_forest prophet arima lstm)
  @sensitivities ~w(low medium high)
  @states ~w(training validating active retraining failed)
  schema "anomaly_models" do
    field(:name, :string)
    field(:description, :string)
    belongs_to(:metric, MetricDefinition, type: :binary_id)
    has_many(:anomalies, Anomaly, foreign_key: :model_id)
    field(:algorithm, :string)
    field(:sensitivity, :string, default: "medium")
    field(:state, :string, default: "training")
    field(:training_window_days, :integer, default: 30)
    field(:detection_interval, :integer, default: 60)
    field(:parameters, :map, default: %{})
    field(:model_data, :binary)
    field(:version, :integer, default: 1)
    field(:accuracy, :float)
    field(:precision, :float)
    field(:recall, :float)
    field(:f1_score, :float)
    field(:training_samples, :integer)
    field(:trained_at, :utc_datetime_usec)
    field(:last_detection_at, :utc_datetime_usec)
    field(:anomaly_count, :integer, default: 0)
    field(:false_positive_count, :integer, default: 0)
    field(:enabled, :boolean, default: true)
    field(:team, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :name,
      :description,
      :metric_id,
      :algorithm,
      :sensitivity,
      :state,
      :training_window_days,
      :detection_interval,
      :parameters,
      :model_data,
      :version,
      :accuracy,
      :precision,
      :recall,
      :f1_score,
      :training_samples,
      :trained_at,
      :enabled,
      :team
    ])
    |> validate_required([:name, :metric_id, :algorithm])
    |> validate_inclusion(:algorithm, @algorithms)
    |> validate_inclusion(:sensitivity, @sensitivities)
    |> validate_inclusion(:state, @states)
    |> validate_training_window()
    |> validate_detection_interval()
    |> validate_parameters()
    |> foreign_key_constraint(:metric_id)
    |> unique_constraint([:name, :metric_id])
  end

  defp validate_training_window(changeset) do
    validate_number(changeset, :training_window_days,
      greater_than: 0,
      less_than_or_equal_to: 365
    )
  end

  defp validate_detection_interval(changeset) do
    validate_number(changeset, :detection_interval,
      greater_than: 0,
      less_than_or_equal_to: 3600
    )
  end

  defp validate_parameters(changeset) do
    algorithm = get_field(changeset, :algorithm)
    parameters = get_field(changeset, :parameters) || %{}

    case validate_algorithm_parameters(algorithm, parameters) do
      :ok ->
        changeset

      {:error, message} ->
        add_error(changeset, :parameters, message)
    end
  end

  defp validate_algorithm_parameters("z_score", params) do
    if is_number(params["threshold"]) and params["threshold"] > 0 do
      :ok
    else
      {:error, "z_score requires threshold > 0"}
    end
  end

  defp validate_algorithm_parameters("iqr", params) do
    if is_number(params["multiplier"]) and params["multiplier"] > 0 do
      :ok
    else
      {:error, "iqr requires multiplier > 0"}
    end
  end

  defp validate_algorithm_parameters("isolation_forest", params) do
    contamination = params["contamination"] || 0.1

    if is_number(contamination) and contamination > 0 and contamination < 0.5 do
      :ok
    else
      {:error, "isolation_forest requires contamination between 0 and 0.5"}
    end
  end

  defp validate_algorithm_parameters(_algorithm, _params) do
    :ok
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update(model, attrs) do
    model
    |> changeset(attrs)
    |> Repo.update()
  end

  def enable(model) do
    model
    |> change(enabled: true)
    |> Repo.update()
  end

  def disable(model) do
    model
    |> change(enabled: false)
    |> Repo.update()
  end

  def list_enabled do
    from(m in __MODULE__,
      where: m.enabled == true,
      order_by: [asc: m.name]
    )
    |> Repo.all()
  end

  def list_by_metric(metric_id) do
    from(m in __MODULE__,
      where: m.metric_id == ^metric_id and m.enabled == true,
      order_by: [desc: m.accuracy]
    )
    |> Repo.all()
  end

  def due_for_detection do
    now = DateTime.utc_now()

    from(m in __MODULE__,
      where: m.enabled == true,
      where: m.state == "active",
      where:
        is_nil(m.last_detection_at) or
          fragment(
            "EXTRACT(EPOCH FROM (? - ?)) >= ?",
            ^now,
            m.last_detection_at,
            m.detection_interval
          )
    )
    |> Repo.all()
  end

  def due_for_retraining(retrain_days \\ 7) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retrain_days * 86400, :second)

    from(m in __MODULE__,
      where: m.enabled == true,
      where: m.state == "active",
      where: is_nil(m.trained_at) or m.trained_at < ^cutoff,
      order_by: [asc: m.trained_at]
    )
    |> Repo.all()
  end

  def train(model) do
    model
    |> change(
      state: "training",
      version: model.version + 1
    )
    |> Repo.update()
  end

  def complete_training(model, attrs) do
    model
    |> changeset(
      Map.merge(attrs, %{
        state: "active",
        trained_at: DateTime.utc_now()
      })
    )
    |> Repo.update()
  end

  def fail_training(model, reason) do
    model
    |> change(state: "failed")
    |> Repo.update()
  end

  def detect(model, metric_samples) do
    model
    |> change(last_detection_at: DateTime.utc_now())
    |> Repo.update()

    {:ok, []}
  end

  def record_anomaly(model, attrs) do
    Repo.transaction(fn ->
      anomaly_attrs = Map.put(attrs, :model_id, model.id)
      {:ok, anomaly} = Anomaly.create(anomaly_attrs)

      model
      |> change(anomaly_count: model.anomaly_count + 1)
      |> Repo.update!()

      anomaly
    end)
  end

  def record_false_positive(model) do
    model
    |> change(false_positive_count: model.false_positive_count + 1)
    |> Repo.update()
  end

  def accuracy_metrics(model) do
    {:ok,
     %{
       accuracy: model.accuracy,
       precision: model.precision,
       recall: model.recall,
       f1_score: model.f1_score,
       total_anomalies: model.anomaly_count,
       false_positives: model.false_positive_count,
       false_positive_rate:
         if(model.anomaly_count > 0,
           do: model.false_positive_count / model.anomaly_count,
           else: 0.0
         )
     }}
  end

  def performance_stats do
    query = """
    SELECT
      algorithm,
      COUNT(*) as model_count,
      AVG(accuracy) as avg_accuracy,
      AVG(precision) as avg_precision,
      AVG(recall) as avg_recall,
      AVG(f1_score) as avg_f1,
      SUM(anomaly_count) as total_anomalies,
      SUM(false_positive_count) as total_false_positives
    FROM anomaly_models
    WHERE enabled = true AND state = 'active'
    GROUP BY algorithm
    ORDER BY avg_f1 DESC
    """

    case Repo.query(query) do
      {:ok, %{rows: rows}} ->
        stats =
          Enum.map(rows, fn [
                              algorithm,
                              count,
                              accuracy,
                              precision,
                              recall,
                              f1,
                              anomalies,
                              fps
                            ] ->
            %{
              algorithm: algorithm,
              model_count: count,
              avg_accuracy: Float.round(accuracy || 0.0, 4),
              avg_precision: Float.round(precision || 0.0, 4),
              avg_recall: Float.round(recall || 0.0, 4),
              avg_f1_score: Float.round(f1 || 0.0, 4),
              total_anomalies: anomalies,
              total_false_positives: fps,
              false_positive_rate: if(anomalies > 0, do: fps / anomalies, else: 0.0)
            }
          end)

        {:ok, stats}

      _ ->
        {:error, :query_failed}
    end
  end

  def best_performing(limit \\ 10) do
    from(m in __MODULE__,
      where: m.enabled == true,
      where: m.state == "active",
      where: not is_nil(m.f1_score),
      order_by: [desc: m.f1_score],
      limit: ^limit
    )
    |> Repo.all()
  end

  def high_false_positives(threshold \\ 0.3) do
    from(m in __MODULE__,
      where: m.enabled == true,
      where: m.anomaly_count > 10,
      where: fragment("? / ?::float > ?", m.false_positive_count, m.anomaly_count, ^threshold),
      order_by: [desc: fragment("? / ?::float", m.false_positive_count, m.anomaly_count)]
    )
    |> Repo.all()
  end
end
