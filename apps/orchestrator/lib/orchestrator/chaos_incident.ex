defmodule Orchestrator.ChaosIncident do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "chaos_incidents" do
    field(:kind, :string)
    field(:target, :string)
    field(:severity, :float, default: 0.5)
    field(:payload, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [:kind, :target, :severity, :payload, :started_at, :ended_at])
    |> validate_required([:kind, :started_at])
  end
end
