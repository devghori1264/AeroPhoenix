defmodule Orchestrator.Machine do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "machines" do
    field :name, :string
    field :region, :string
    field :status, :string
    field :version, :integer, default: 1
    field :cpu, :float, default: 0.0
    field :memory_mb, :integer, default: 0
    field :latency_ms, :float, default: 0.0
    field :metadata, :map, default: %{}
    field :last_seen_at, :utc_datetime_usec
    timestamps()
  end

  @required_fields ~w(name region status)a
  @optional_fields ~w(version cpu memory_mb latency_ms metadata last_seen_at)a

  def changeset(machine, attrs) do
    machine
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["pending", "running", "migrating", "stopped", "terminated"])
  end

  def telemetry_changeset(machine, attrs) do
    machine
    |> cast(attrs, [:cpu, :memory_mb, :latency_ms, :last_seen_at])
    |> validate_number(:cpu, greater_than_or_equal_to: 0.0)
    |> validate_number(:memory_mb, greater_than_or_equal_to: 0)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0.0)
  end
end
