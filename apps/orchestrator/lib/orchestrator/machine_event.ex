defmodule Orchestrator.MachineEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "machine_events" do
    field :machine_id, :binary_id
    field :type, :string
    field :payload, :map
    field :created_at, :utc_datetime_usec, default: fragment("now()")
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:machine_id, :type, :payload, :created_at])
    |> validate_required([:machine_id, :type])
  end
end
