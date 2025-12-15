defmodule Orchestrator.Repo.Migrations.CreateChaosIncidents do
  use Ecto.Migration

  def change do
    create table(:chaos_incidents, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:kind, :string, null: false)
      add(:target, :string)
      add(:severity, :float, default: 0.5)
      add(:payload, :map)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:chaos_incidents, [:kind]))
    create(index(:chaos_incidents, [:started_at]))
  end
end
