defmodule Orchestrator.Repo.Migrations.CreateEventStore do
  use Ecto.Migration

  def up do
    create_events_table()
    create_snapshots_table()
    create_subscriptions_table()
    create_indexes()
  end

  def down do
    drop(table(:event_subscriptions))
    drop(table(:event_snapshots))
    drop(table(:events))
  end

  defp create_events_table do
    create table(:events, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:event_type, :string, null: false)
      add(:event_version, :integer, null: false, default: 1)
      add(:aggregate_id, :uuid, null: false)
      add(:aggregate_type, :string, null: false)
      add(:aggregate_version, :bigint, null: false)
      add(:data, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:causation_id, :uuid)
      add(:correlation_id, :uuid)
      add(:vector_clock, :map, null: false, default: %{})
      add(:actor_id, :uuid)
      add(:actor_type, :string)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:recorded_at, :utc_datetime_usec, null: false)
      add(:tags, {:array, :string}, default: [])
    end
  end

  defp create_snapshots_table do
    create table(:event_snapshots, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:aggregate_id, :uuid, null: false)
      add(:aggregate_type, :string, null: false)
      add(:aggregate_version, :bigint, null: false)
      add(:state, :map, null: false)
      add(:last_event_id, :uuid, null: false)
      add(:event_count, :integer, null: false)
      add(:checksum, :string, null: false)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defp create_subscriptions_table do
    create table(:event_subscriptions) do
      add(:name, :string, null: false)
      add(:subscriber_id, :uuid, null: false)
      add(:last_event_id, :uuid)
      add(:last_event_version, :bigint, default: 0)
      add(:event_types, {:array, :string}, default: [])
      add(:status, :string, default: "active")
      add(:events_processed, :bigint, default: 0)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defp create_indexes do
    create(index(:events, [:occurred_at]))
    create(index(:events, [:aggregate_type, :aggregate_id, :aggregate_version]))
    create(unique_index(:events, [:aggregate_id, :aggregate_version]))
    create(index(:events, [:event_type, :occurred_at]))
    create(index(:events, [:correlation_id], where: "correlation_id IS NOT NULL"))
    # GIN indexes removed for SQLite

    create(unique_index(:event_snapshots, [:aggregate_id, :aggregate_version]))
    create(unique_index(:event_subscriptions, [:name]))
    create(index(:event_subscriptions, [:subscriber_id]))
  end
end
