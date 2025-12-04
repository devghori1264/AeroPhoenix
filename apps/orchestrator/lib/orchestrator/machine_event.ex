defmodule Orchestrator.MachineEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "machine_events" do
    field(:machine_id, :binary_id)
    field(:type, :string)
    field(:payload, :map)

    timestamps(updated_at: false, inserted_at: :created_at)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:machine_id, :type, :payload, :created_at])
    |> validate_required([:machine_id, :type])
  end
end
