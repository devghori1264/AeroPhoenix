defmodule Orchestrator.Repo.Migrations.CreateEventStore do
  use Ecto.Migration
  def up do
    execute("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")
    execute("CREATE EXTENSION IF NOT EXISTS \"btree_gist\"")
    create_event_type_enum()
    create_events_table()
    create_snapshots_table()
    create_subscriptions_table()
    create_indexes()
    create_functions()
  end
  def down do
    execute("DROP FUNCTION IF EXISTS get_event_stream CASCADE")
    execute("DROP FUNCTION IF EXISTS should_create_snapshot CASCADE")
    drop(table(:event_subscriptions))
    drop(table(:event_snapshots))
    drop(table(:events))
    execute("DROP TYPE IF EXISTS event_type CASCADE")
  end
  defp create_event_type_enum do
    execute("""
    CREATE TYPE event_type AS ENUM (
      'machine_created', 'machine_started', 'machine_stopped', 'machine_destroyed',
      'state_transition_started', 'state_transition_completed', 'state_transition_failed',
      'migration_initiated', 'migration_completed', 'migration_failed',
      'resource_allocated', 'resource_deallocated', 'resource_throttled',
      'config_updated', 'health_check_failed', 'health_check_passed',
      'debug_session_started', 'debug_breakpoint_hit', 'debug_snapshot_created',
      'cost_threshold_exceeded', 'scale_up_triggered', 'scale_down_triggered',
      'feature_enabled', 'feature_disabled', 'system_error', 'system_metric_recorded'
    )
    """)
  end
  defp create_events_table do
    create table(:events, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:event_type, :event_type, null: false)
      add(:event_version, :integer, null: false, default: 1)
      add(:aggregate_id, :uuid, null: false)
      add(:aggregate_type, :string, null: false)
      add(:aggregate_version, :bigint, null: false)
      add(:data, :jsonb, null: false, default: "{}")
      add(:metadata, :jsonb, null: false, default: "{}")
      add(:causation_id, :uuid)
      add(:correlation_id, :uuid)
      add(:vector_clock, :jsonb, null: false, default: "{}")
      add(:actor_id, :uuid)
      add(:actor_type, :string)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:recorded_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:tags, {:array, :string}, default: [])
    end
  end
  defp create_snapshots_table do
    create table(:event_snapshots, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()"))
      add(:aggregate_id, :uuid, null: false)
      add(:aggregate_type, :string, null: false)
      add(:aggregate_version, :bigint, null: false)
      add(:state, :jsonb, null: false)
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
    execute("CREATE INDEX events_data_gin_idx ON events USING GIN (data)")
    execute("CREATE INDEX events_metadata_gin_idx ON events USING GIN (metadata)")
    create(index(:event_snapshots, [:aggregate_id, :aggregate_version]))
    create(unique_index(:event_snapshots, [:aggregate_id, :aggregate_version]))
    create(unique_index(:event_subscriptions, [:name]))
    create(index(:event_subscriptions, [:subscriber_id]))
  end
  defp create_functions do
    execute("""
    CREATE OR REPLACE FUNCTION should_create_snapshot(
      p_aggregate_id UUID,
      p_aggregate_version BIGINT,
      p_snapshot_interval INTEGER DEFAULT 100
    ) RETURNS BOOLEAN AS $$
    DECLARE
      v_last_snapshot_version BIGINT;
    BEGIN
      SELECT COALESCE(MAX(aggregate_version), 0)
      INTO v_last_snapshot_version
      FROM event_snapshots
      WHERE aggregate_id = p_aggregate_id;
      RETURN (p_aggregate_version - v_last_snapshot_version) >= p_snapshot_interval;
    END;
    $$ LANGUAGE plpgsql STABLE;
    """)
    execute("""
    CREATE OR REPLACE FUNCTION get_event_stream(
      p_aggregate_id UUID,
      p_from_version BIGINT DEFAULT 0,
      p_to_version BIGINT DEFAULT NULL,
      p_limit INTEGER DEFAULT 1000
    ) RETURNS TABLE (
      id UUID,
      event_type TEXT,
      aggregate_version BIGINT,
      data JSONB,
      metadata JSONB,
      occurred_at TIMESTAMP WITH TIME ZONE
    ) AS $$
    BEGIN
      RETURN QUERY
      SELECT
        e.id, e.event_type::TEXT, e.aggregate_version,
        e.data, e.metadata, e.occurred_at
      FROM events e
      WHERE e.aggregate_id = p_aggregate_id
        AND e.aggregate_version > p_from_version
        AND (p_to_version IS NULL OR e.aggregate_version <= p_to_version)
      ORDER BY e.aggregate_version ASC
      LIMIT p_limit;
    END;
    $$ LANGUAGE plpgsql STABLE;
    """)
  end
end
