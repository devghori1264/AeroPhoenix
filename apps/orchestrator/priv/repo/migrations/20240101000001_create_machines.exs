defmodule Orchestrator.Repo.Migrations.CreateMachines do
  use Ecto.Migration

  def change do
    create table(:machines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :region, :string, null: false
      add :status, :string, null: false
      add :machine_type, :string, null: false
      add :cpu, :float, default: 0.0
      add :cpu_count, :integer, default: 1
      add :memory_mb, :integer, default: 256
      add :latency_ms, :float, default: 0.0
      add :service, :string
      add :config, :map, default: %{}
      add :tags, :map, default: %{}
      add :version, :integer, default: 1
      add :metadata, :map, default: %{}
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:machines, [:name])
    create index(:machines, [:region])
    create index(:machines, [:status])
    create index(:machines, [:service])
  end
end
