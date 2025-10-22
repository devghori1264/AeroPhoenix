defmodule Orchestrator.Repo.Migrations.CreateMachines do
  use Ecto.Migration

  def change do
    create table(:machines, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :region, :string, null: false
      add :status, :string, null: false
      add :version, :bigint, default: 1
      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:machines, [:region])
    create index(:machines, [:status])
  end
end
