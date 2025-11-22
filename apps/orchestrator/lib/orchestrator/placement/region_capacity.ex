defmodule Orchestrator.Placement.RegionCapacity do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "region_capacities" do
    field(:region, :string)
    field(:total_cpu_cores, :integer)
    field(:total_memory_gb, :integer)
    field(:total_disk_gb, :integer)
    field(:used_cpu_cores, :integer, default: 0)
    field(:used_memory_gb, :integer, default: 0)
    field(:used_disk_gb, :integer, default: 0)
    field(:utilization, :float, default: 0.0)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(capacity, attrs) do
    capacity
    |> cast(attrs, [
      :region,
      :total_cpu_cores,
      :total_memory_gb,
      :total_disk_gb,
      :used_cpu_cores,
      :used_memory_gb,
      :used_disk_gb,
      :utilization,
      :metadata
    ])
    |> validate_required([:region, :total_cpu_cores, :total_memory_gb, :total_disk_gb])
    |> unique_constraint(:region)
  end
end
