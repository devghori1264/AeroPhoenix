defmodule Orchestrator.Repo.Migrations.CreateMetricDefinitions do
  use Ecto.Migration

  def change do
    create table(:metric_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string, null: false
      add :unit, :string, null: false
      add :help, :string
      add :namespace, :string
      add :subsystem, :string
      add :label_keys, {:array, :string}, default: []
      add :cardinality, :integer, default: 0
      add :retention_days, :integer, default: 90
      add :compression_enabled, :boolean, default: true
      add :compress_after_hours, :integer, default: 1
      add :enabled, :boolean, default: true
      add :created_by, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:metric_definitions, [:name])
    create index(:metric_definitions, [:namespace])
    create index(:metric_definitions, [:type])
    create index(:metric_definitions, [:enabled])
  end
end
