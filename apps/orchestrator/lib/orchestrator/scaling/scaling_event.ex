defmodule Orchestrator.Scaling.ScalingEvent do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "scaling_events" do
    field(:service_name, :string)

    field(:event_type, Ecto.Enum,
      values: [:scale_out, :scale_in, :prevented_by_cooldown, :no_action]
    )

    field(:trigger_reason, :string)
    field(:previous_instance_count, :integer)
    field(:new_instance_count, :integer)
    field(:cpu_utilization, :float)
    field(:memory_utilization, :float)
    field(:request_rate, :float)
    field(:prediction_confidence, :float)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :service_name,
      :event_type,
      :trigger_reason,
      :previous_instance_count,
      :new_instance_count,
      :cpu_utilization,
      :memory_utilization,
      :request_rate,
      :prediction_confidence,
      :metadata
    ])
    |> validate_required([:service_name, :event_type, :trigger_reason])
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end

  def for_service(service_name, hours) do
    import Ecto.Query
    cutoff = DateTime.utc_now() |> DateTime.add(-hours, :hour)

    from(e in __MODULE__,
      where: e.service_name == ^service_name and e.inserted_at >= ^cutoff,
      order_by: [desc: e.inserted_at]
    )
    |> Orchestrator.Repo.all()
  end
end
