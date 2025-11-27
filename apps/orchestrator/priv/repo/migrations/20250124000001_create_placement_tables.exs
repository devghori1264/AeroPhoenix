defmodule Orchestrator.Repo.Migrations.CreatePlacementTables do
  use Ecto.Migration

  def change do
    create table(:region_capacities, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:region, :string, null: false)
      add(:total_cpu_cores, :integer, null: false)
      add(:total_memory_gb, :integer, null: false)
      add(:total_disk_gb, :integer, null: false)
      add(:used_cpu_cores, :integer, default: 0)
      add(:used_memory_gb, :integer, default: 0)
      add(:used_disk_gb, :integer, default: 0)
      add(:utilization, :float, default: 0.0)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:region_capacities, [:region]))
    create(index(:region_capacities, [:utilization]))
  end
end
