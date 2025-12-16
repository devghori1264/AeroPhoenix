defmodule Orchestrator.Repo.Migrations.CreateMachineEvents do
  use Ecto.Migration

  def change do
    create table(:machine_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :machine_id, :binary_id, null: false
      add :type, :string, null: false
      add :payload, :map, default: %{}
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:machine_events, [:machine_id])
    create index(:machine_events, [:type])
    create index(:machine_events, [:created_at])
  end
end
