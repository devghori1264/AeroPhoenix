defmodule Orchestrator.Repo.Migrations.UpdateMachinesTable do
  use Ecto.Migration

  def change do
    alter table(:machines) do
      add :machine_type, :string
      add :service, :string
      add :cpu_count, :integer, default: 1
      add :config, :map, default: %{}
      add :tags, :map, default: %{}
    end

    create index(:machines, [:service])
  end
end
