defmodule Orchestrator.Repo.Migrations.CreateReplicationTables do
  use Ecto.Migration

  def change do
    create table(:replication_log, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :term, :integer, null: false
      add :index, :integer, null: false
      add :command, :map, null: false
      add :node_id, :string, null: false
      add :timestamp, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:replication_log, [:node_id])
    create index(:replication_log, [:term, :index])
    create unique_index(:replication_log, [:node_id, :index])

    create table(:replication_state, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :node_id, :string, null: false
      add :current_term, :integer, default: 0
      add :voted_for, :string
      add :commit_index, :integer, default: 0
      add :last_applied, :integer, default: 0
      add :role, :string, default: "follower"
      add :leader_id, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:replication_state, [:node_id])

    create table(:vector_clocks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :entity_id, :string, null: false
      add :node_id, :string, null: false
      add :clock_value, :integer, default: 0
      add :timestamp, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:vector_clocks, [:entity_id])
    create unique_index(:vector_clocks, [:entity_id, :node_id])
  end
end
