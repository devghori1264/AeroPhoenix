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
end
