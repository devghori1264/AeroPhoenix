defmodule Orchestrator.Metrics.SLAViolation do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.SLADefinition
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sla_violations" do
    belongs_to(:sla, SLADefinition, type: :binary_id)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:duration_seconds, :integer)
    field(:actual_value, :float)
    field(:target_value, :float)
    field(:error_budget_consumed, :float)
    field(:severity, Ecto.Enum, values: [:low, :medium, :high, :critical])
    field(:labels, :map)
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(violation, attrs) do
    violation
    |> cast(attrs, [
      :sla_id,
      :started_at,
      :ended_at,
      :actual_value,
      :target_value,
      :error_budget_consumed,
      :severity,
      :labels
    ])
    |> validate_required([:sla_id, :started_at, :actual_value, :target_value])
    |> foreign_key_constraint(:sla_id)
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def resolve(violation) do
    now = DateTime.utc_now()
    duration = DateTime.diff(now, violation.started_at)

    violation
    |> change(ended_at: now, duration_seconds: duration)
    |> Repo.update()
  end

  def active do
    from(v in __MODULE__,
      where: is_nil(v.ended_at),
      order_by: [desc: v.started_at]
    )
    |> Repo.all()
  end

  def for_sla(sla_id, limit \\ 50) do
    from(v in __MODULE__,
      where: v.sla_id == ^sla_id,
      order_by: [desc: v.started_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def recent(hours \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    from(v in __MODULE__,
      where: v.started_at >= ^cutoff,
      order_by: [desc: v.started_at]
    )
    |> Repo.all()
  end
end
