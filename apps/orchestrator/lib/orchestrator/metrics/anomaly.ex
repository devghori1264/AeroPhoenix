defmodule Orchestrator.Metrics.Anomaly do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.{AnomalyModel, MetricDefinition}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @severities ~w(info warning critical)
  @states ~w(new investigating resolved false_positive acknowledged)
  schema "anomalies" do
    belongs_to(:model, AnomalyModel, type: :binary_id)
    belongs_to(:metric, MetricDefinition, type: :binary_id)
    field(:timestamp, :utc_datetime_usec)
    field(:actual_value, :float)
    field(:expected_value, :float)
    field(:anomaly_score, :float)
    field(:severity, :string)
    field(:state, :string, default: "new")
    field(:labels, :map)
    field(:context, :map)
    field(:investigated_at, :utc_datetime_usec)
    field(:investigated_by, :string)
    field(:resolution_notes, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(anomaly, attrs) do
    anomaly
    |> cast(attrs, [
      :model_id,
      :metric_id,
      :timestamp,
      :actual_value,
      :expected_value,
      :anomaly_score,
      :severity,
      :state,
      :labels,
      :context,
      :investigated_by,
      :resolution_notes
    ])
    |> validate_required([
      :model_id,
      :metric_id,
      :timestamp,
      :actual_value,
      :anomaly_score
    ])
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:state, @states)
    |> foreign_key_constraint(:model_id)
    |> foreign_key_constraint(:metric_id)
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update(anomaly, attrs) do
    anomaly
    |> changeset(attrs)
    |> Repo.update()
  end

  def start_investigation(anomaly, investigator) do
    anomaly
    |> change(
      state: "investigating",
      investigated_at: DateTime.utc_now(),
      investigated_by: investigator
    )
    |> Repo.update()
  end

  def resolve(anomaly, notes) do
    anomaly
    |> change(state: "resolved", resolution_notes: notes)
    |> Repo.update()
  end

  def mark_false_positive(anomaly, notes) do
    Repo.transaction(fn ->
      anomaly =
        anomaly
        |> change(state: "false_positive", resolution_notes: notes)
        |> Repo.update!()

      model = Repo.get!(AnomalyModel, anomaly.model_id)
      AnomalyModel.record_false_positive(model)
      anomaly
    end)
  end

  def acknowledge(anomaly) do
    anomaly
    |> change(state: "acknowledged")
    |> Repo.update()
  end

  def new do
    from(a in __MODULE__,
      where: a.state == "new",
      order_by: [desc: a.anomaly_score, desc: a.timestamp]
    )
    |> Repo.all()
  end

  def critical do
    from(a in __MODULE__,
      where: a.severity == "critical",
      where: a.state in ["new", "investigating"],
      order_by: [desc: a.timestamp]
    )
    |> Repo.all()
  end

  def recent(hours \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    from(a in __MODULE__,
      where: a.timestamp >= ^cutoff,
      order_by: [desc: a.timestamp]
    )
    |> Repo.all()
  end

  def for_metric(metric_id, limit \\ 100) do
    from(a in __MODULE__,
      where: a.metric_id == ^metric_id,
      order_by: [desc: a.timestamp],
      limit: ^limit
    )
    |> Repo.all()
  end

  def for_model(model_id, limit \\ 100) do
    from(a in __MODULE__,
      where: a.model_id == ^model_id,
      order_by: [desc: a.timestamp],
      limit: ^limit
    )
    |> Repo.all()
  end

  def stats(hours \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    query = """
    SELECT
      COUNT(*) as total,
      COUNT(*) FILTER (WHERE state = 'new') as new_count,
      COUNT(*) FILTER (WHERE state = 'investigating') as investigating_count,
      COUNT(*) FILTER (WHERE state = 'resolved') as resolved_count,
      COUNT(*) FILTER (WHERE state = 'false_positive') as false_positive_count,
      COUNT(*) FILTER (WHERE severity = 'critical') as critical_count,
      AVG(anomaly_score) as avg_score
    FROM anomalies
    WHERE timestamp >= $1
    """

    case Repo.query(query, [cutoff]) do
      {:ok,
       %{
         rows: [
           [total, new, investigating, resolved, false_positive, critical, avg_score]
         ]
       }} ->
        {:ok,
         %{
           total: total,
           by_state: %{
             new: new,
             investigating: investigating,
             resolved: resolved,
             false_positive: false_positive
           },
           critical: critical,
           avg_score: Float.round(avg_score || 0.0, 2)
         }}

      _ ->
        {:error, :query_failed}
    end
  end
end
