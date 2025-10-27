defmodule Orchestrator.Repo.Migrations.CreateMachinesAndEvents do
  use Ecto.Migration

  def change do
    create table(:machines, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :region, :string, null: false
      add :status, :string, null: false
      add :version, :bigint, default: 1
      add :cpu, :float, default: 0.0
      add :memory_mb, :integer, default: 0
      add :latency_ms, :float, default: 0.0
      add :metadata, :map, default: %{}
      add :last_seen_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:machines, [:region])
    create index(:machines, [:status])

    create table(:machine_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :machine_id, references(:machines, type: :uuid, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :payload, :map, default: %{}
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:machine_events, [:machine_id])
  end
end
