defmodule Orchestrator.Machine do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "machines" do
    field :name, :string
    field :region, :string
    field :status, :string
    field :version, :integer, default: 1
    field :metadata, :map, default: %{}
    timestamps()
  end

  def changeset(machine, attrs) do
    machine
    |> cast(attrs, [:name, :region, :status, :version, :metadata])
    |> validate_required([:name, :region, :status])
    |> validate_inclusion(:status, ["pending", "running", "migrating", "stopped", "terminated"])
  end
end
