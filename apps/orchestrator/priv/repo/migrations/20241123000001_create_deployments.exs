defmodule Orchestrator.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def up do
    # Deployment-specific enums

    execute("""
    CREATE TYPE deployment_strategy AS ENUM (
      'rolling',
      'blue_green',
      'canary',
      'recreate',
      'ramped',
      'shadow'
    )
    """)

    execute("""
    CREATE TYPE deployment_status AS ENUM (
      'pending',
      'initializing',
      'in_progress',
      'paused',
      'succeeded',
      'failed',
      'rolled_back',
      'cancelled'
    )
    """)

    execute("""
    CREATE TYPE deployment_phase AS ENUM (
      'preparing',
      'provisioning',
      'deploying',
      'health_checking',
      'traffic_shifting',
      'monitoring',
      'completing',
      'cleaning_up'
    )
    """)

    execute("""
    CREATE TYPE traffic_split_type AS ENUM (
      'percentage',
      'header',
      'cookie',
      'query_param',
      'ip_range',
      'user_id'
    )
    """)

    execute("""
    CREATE TYPE health_status AS ENUM (
      'unknown',
      'healthy',
      'degraded',
      'unhealthy',
      'critical'
    )
    """)

    # Deployments table - main deployment orchestration
    create table(:deployments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:service, :string, null: false)
      add(:strategy, :deployment_strategy, null: false)
      add(:status, :deployment_status, null: false, default: "pending")
      add(:current_phase, :deployment_phase)

      # Version tracking
      add(:from_version, :string)
      add(:to_version, :string, null: false)
      add(:artifact_url, :string)
      add(:artifact_hash, :string)
      add(:artifact_size_bytes, :bigint)

      # Configuration
      add(:target_replicas, :integer, null: false)
      add(:min_ready_seconds, :integer, default: 0)
      # 10 minutes
      add(:progress_deadline_seconds, :integer, default: 600)
      add(:revision_history_limit, :integer, default: 10)

      # Strategy-specific configuration
      add(:rolling_config, :map, default: %{})
      add(:blue_green_config, :map, default: %{})
      add(:canary_config, :map, default: %{})

      # Health check configuration
      add(:health_check_path, :string, default: "/health")
      add(:health_check_interval_seconds, :integer, default: 10)
      add(:health_check_timeout_seconds, :integer, default: 5)
      add(:health_check_success_threshold, :integer, default: 1)
      add(:health_check_failure_threshold, :integer, default: 3)

      # Progress tracking
      add(:replicas_ready, :integer, default: 0)
      add(:replicas_updated, :integer, default: 0)
      add(:replicas_available, :integer, default: 0)
      add(:replicas_unavailable, :integer, default: 0)

      # Timing
      add(:started_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:duration_ms, :integer)
      add(:paused_at, :utc_datetime)
      add(:pause_duration_ms, :integer)

      # Rollback information
      add(:rollback_to_version, :string)
      add(:rollback_reason, :text)
      add(:auto_rollback_enabled, :boolean, default: true)
      add(:rollback_on_failure, :boolean, default: true)

      # Metadata
      # user_id, automation, ci_cd
      add(:triggered_by, :string)
      # manual, github, gitlab, jenkins
      add(:trigger_source, :string)
      add(:annotations, :map, default: %{})
      add(:labels, :map, default: %{})
      add(:error_message, :text)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:deployments, [:service]))
    create(index(:deployments, [:strategy]))
    create(index(:deployments, [:status]))
    create(index(:deployments, [:to_version]))
    create(index(:deployments, [:started_at]))
    create(index(:deployments, [:completed_at]))
    create(index(:deployments, [:triggered_by]))

    # Deployment revisions table - track all deployed versions
    create table(:deployment_revisions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :cascade), null: false)
      add(:revision_number, :integer, null: false)
      add(:version, :string, null: false)
      add(:artifact_url, :string, null: false)
      add(:artifact_hash, :string)
      # Full configuration at this revision
      add(:config_snapshot, :map, default: %{})
      add(:replicas, :integer, null: false)
      add(:status, :deployment_status, null: false)
      add(:deployed_at, :utc_datetime, null: false)
      add(:replaced_at, :utc_datetime)
      add(:is_active, :boolean, default: false)
      add(:rollback_count, :integer, default: 0)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:deployment_revisions, [:deployment_id]))
    create(index(:deployment_revisions, [:revision_number]))
    create(index(:deployment_revisions, [:version]))
    create(index(:deployment_revisions, [:is_active]))
    create(unique_index(:deployment_revisions, [:deployment_id, :revision_number]))

    # Deployment replicas table - track individual replica instances
    create table(:deployment_replicas, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :cascade), null: false)

      add(:revision_id, references(:deployment_revisions, type: :uuid, on_delete: :cascade),
        null: false
      )

      add(:replica_name, :string, null: false)
      # Link to machines table if exists
      add(:machine_id, :uuid)
      add(:pod_ip, :string)
      add(:host_ip, :string)
      add(:node_name, :string)

      # Status
      # pending, running, succeeded, failed, unknown
      add(:status, :string, null: false)
      add(:health_status, :health_status, default: "unknown")
      add(:ready, :boolean, default: false)
      add(:restart_count, :integer, default: 0)

      # Health checks
      add(:last_health_check_at, :utc_datetime)
      add(:health_check_success_count, :integer, default: 0)
      add(:health_check_failure_count, :integer, default: 0)
      add(:consecutive_failures, :integer, default: 0)

      # Timing
      add(:created_at_time, :utc_datetime)
      add(:started_at, :utc_datetime)
      add(:ready_at, :utc_datetime)
      add(:terminated_at, :utc_datetime)
      add(:startup_duration_ms, :integer)

      # Traffic
      add(:receiving_traffic, :boolean, default: false)
      add(:traffic_weight, :integer, default: 0)
      add(:requests_received, :bigint, default: 0)
      add(:requests_failed, :bigint, default: 0)

      # Resource metrics
      add(:cpu_usage_percent, :decimal, precision: 5, scale: 2)
      add(:memory_usage_mb, :integer)
      add(:disk_usage_mb, :integer)

      add(:error_message, :text)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:deployment_replicas, [:deployment_id]))
    create(index(:deployment_replicas, [:revision_id]))
    create(index(:deployment_replicas, [:replica_name]))
    create(index(:deployment_replicas, [:status]))
    create(index(:deployment_replicas, [:health_status]))
    create(index(:deployment_replicas, [:ready]))
    create(index(:deployment_replicas, [:receiving_traffic]))
    create(unique_index(:deployment_replicas, [:deployment_id, :replica_name]))

    # Traffic routing rules table
    create table(:traffic_routes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :cascade), null: false)
      add(:name, :string, null: false)
      add(:split_type, :traffic_split_type, null: false)
      add(:enabled, :boolean, default: true)
      add(:priority, :integer, default: 0)

      # Traffic splitting configuration
      # Percentage (0-100)
      add(:old_version_weight, :integer, default: 100)
      add(:new_version_weight, :integer, default: 0)
      add(:sticky_sessions, :boolean, default: false)
      add(:session_affinity_seconds, :integer, default: 3600)

      # Advanced routing rules
      add(:match_headers, :map, default: %{})
      add(:match_cookies, :map, default: %{})
      add(:match_query_params, :map, default: %{})
      add(:match_ip_ranges, {:array, :string}, default: [])
      add(:match_user_ids, {:array, :string}, default: [])

      # Metrics
      add(:requests_old_version, :bigint, default: 0)
      add(:requests_new_version, :bigint, default: 0)
      add(:last_updated_at, :utc_datetime)

      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:traffic_routes, [:deployment_id]))
    create(index(:traffic_routes, [:split_type]))
    create(index(:traffic_routes, [:enabled]))
    create(unique_index(:traffic_routes, [:deployment_id, :name]))

    # Deployment events table - audit trail
    create table(:deployment_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :cascade), null: false)
      # phase_change, replica_created, health_check, traffic_shift
      add(:event_type, :string, null: false)
      # info, warning, error
      add(:event_severity, :string, null: false)
      add(:phase, :deployment_phase)
      add(:message, :text, null: false)
      add(:reason, :string)
      # controller, health_checker, traffic_manager
      add(:component, :string)
      add(:replica_name, :string)
      add(:old_value, :string)
      add(:new_value, :string)
      add(:occurred_at, :utc_datetime, null: false)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    # Hypertable for time-series deployment events
    execute("""
    SELECT create_hypertable(
      'deployment_events',
      'occurred_at',
      chunk_time_interval => INTERVAL '7 days'
    )
    """)

    create(index(:deployment_events, [:deployment_id]))
    create(index(:deployment_events, [:event_type]))
    create(index(:deployment_events, [:event_severity]))
    create(index(:deployment_events, [:occurred_at]))

    # Compression after 30 days
    execute("""
    SELECT add_compression_policy(
      'deployment_events',
      compress_after => INTERVAL '30 days'
    )
    """)

    # Retention policy - keep for 1 year
    execute("""
    SELECT add_retention_policy(
      'deployment_events',
      drop_after => INTERVAL '365 days'
    )
    """)

    # Deployment metrics table
    create table(:deployment_metrics, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :cascade), null: false)
      add(:metric_name, :string, null: false)
      add(:metric_value, :decimal, precision: 20, scale: 4)
      add(:labels, :map, default: %{})
      add(:timestamp, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    # Hypertable for deployment metrics
    execute("""
    SELECT create_hypertable(
      'deployment_metrics',
      'timestamp',
      chunk_time_interval => INTERVAL '1 day'
    )
    """)

    create(index(:deployment_metrics, [:deployment_id]))
    create(index(:deployment_metrics, [:metric_name]))
    create(index(:deployment_metrics, [:timestamp]))

    # Compression after 7 days
    execute("""
    SELECT add_compression_policy(
      'deployment_metrics',
      compress_after => INTERVAL '7 days'
    )
    """)

    # Canary analysis results table
    create table(:canary_analysis_results, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :cascade), null: false)
      add(:analysis_run, :integer, null: false)
      add(:started_at, :utc_datetime, null: false)
      add(:completed_at, :utc_datetime)
      add(:duration_ms, :integer)

      # Analysis configuration
      add(:baseline_version, :string, null: false)
      add(:canary_version, :string, null: false)
      # Canary traffic percentage
      add(:traffic_percentage, :integer)

      # Metric comparisons
      add(:success_rate_baseline, :decimal, precision: 5, scale: 2)
      add(:success_rate_canary, :decimal, precision: 5, scale: 2)
      add(:latency_p50_baseline_ms, :integer)
      add(:latency_p50_canary_ms, :integer)
      add(:latency_p95_baseline_ms, :integer)
      add(:latency_p95_canary_ms, :integer)
      add(:latency_p99_baseline_ms, :integer)
      add(:latency_p99_canary_ms, :integer)
      add(:error_rate_baseline, :decimal, precision: 5, scale: 2)
      add(:error_rate_canary, :decimal, precision: 5, scale: 2)

      # Decision
      add(:passed, :boolean)
      add(:score, :decimal, precision: 5, scale: 2)
      # promote, abort, continue
      add(:recommendation, :string)
      add(:failure_reasons, {:array, :string}, default: [])

      # Thresholds used
      add(:success_rate_threshold, :decimal, precision: 5, scale: 2)
      add(:latency_threshold_ms, :integer)
      add(:error_rate_threshold, :decimal, precision: 5, scale: 2)

      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:canary_analysis_results, [:deployment_id]))
    create(index(:canary_analysis_results, [:analysis_run]))
    create(index(:canary_analysis_results, [:passed]))
    create(index(:canary_analysis_results, [:started_at]))

    # Deployment hooks table - pre/post deployment actions
    create table(:deployment_hooks, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :cascade), null: false)
      # pre_deployment, post_deployment, pre_rollback, post_rollback
      add(:hook_type, :string, null: false)
      add(:hook_name, :string, null: false)
      add(:execution_order, :integer, default: 0)
      add(:command, :text, null: false)
      add(:timeout_seconds, :integer, default: 300)
      add(:retry_count, :integer, default: 0)
      add(:max_retries, :integer, default: 3)
      add(:continue_on_failure, :boolean, default: false)

      # Execution tracking
      # pending, running, succeeded, failed, skipped
      add(:status, :string)
      add(:started_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:duration_ms, :integer)
      add(:exit_code, :integer)
      add(:stdout, :text)
      add(:stderr, :text)
      add(:error_message, :text)

      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:deployment_hooks, [:deployment_id]))
    create(index(:deployment_hooks, [:hook_type]))
    create(index(:deployment_hooks, [:status]))
    create(index(:deployment_hooks, [:execution_order]))

    # Functions for auto-updating deployment progress

    execute("""
    CREATE OR REPLACE FUNCTION update_deployment_progress()
    RETURNS TRIGGER AS $$
    BEGIN
      UPDATE deployments
      SET
        replicas_ready = (
          SELECT COUNT(*)
          FROM deployment_replicas
          WHERE deployment_id = NEW.deployment_id AND ready = true
        ),
        replicas_available = (
          SELECT COUNT(*)
          FROM deployment_replicas
          WHERE deployment_id = NEW.deployment_id AND status = 'running' AND ready = true
        ),
        replicas_updated = (
          SELECT COUNT(*)
          FROM deployment_replicas dr
          INNER JOIN deployment_revisions drev ON dr.revision_id = drev.id
          WHERE dr.deployment_id = NEW.deployment_id AND drev.is_active = true
        ),
        replicas_unavailable = (
          SELECT COUNT(*)
          FROM deployment_replicas
          WHERE deployment_id = NEW.deployment_id AND (ready = false OR status != 'running')
        )
      WHERE id = NEW.deployment_id;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER trigger_update_deployment_progress
    AFTER INSERT OR UPDATE OF ready, status ON deployment_replicas
    FOR EACH ROW
    EXECUTE FUNCTION update_deployment_progress();
    """)

    # Materialized view for deployment dashboard
    execute("""
    CREATE MATERIALIZED VIEW deployment_dashboard AS
    SELECT
      d.service,
      d.strategy,
      COUNT(DISTINCT d.id) as total_deployments,
      COUNT(DISTINCT d.id) FILTER (WHERE d.status = 'succeeded') as successful_deployments,
      COUNT(DISTINCT d.id) FILTER (WHERE d.status = 'failed') as failed_deployments,
      COUNT(DISTINCT d.id) FILTER (WHERE d.status = 'in_progress') as active_deployments,
      AVG(d.duration_ms) FILTER (WHERE d.status = 'succeeded') as avg_deployment_duration_ms,
      MAX(d.completed_at) as last_deployment_at,
      AVG(
        CASE
          WHEN d.status = 'succeeded' THEN 1.0
          WHEN d.status = 'failed' THEN 0.0
          ELSE NULL
        END
      ) * 100 as success_rate_percent,
      COUNT(DISTINCT d.id) FILTER (WHERE d.status = 'rolled_back') as rollback_count
    FROM deployments d
    WHERE d.created_at >= NOW() - INTERVAL '30 days'
    GROUP BY d.service, d.strategy
    """)

    create(unique_index(:deployment_dashboard, [:service, :strategy]))

    # Continuous aggregate for deployment success rate over time
    execute("""
    CREATE MATERIALIZED VIEW deployment_success_rate_hourly
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', completed_at) as hour,
      service,
      strategy,
      COUNT(*) as total_count,
      COUNT(*) FILTER (WHERE status = 'succeeded') as success_count,
      COUNT(*) FILTER (WHERE status = 'failed') as failure_count,
      AVG(duration_ms) as avg_duration_ms
    FROM deployments
    WHERE completed_at IS NOT NULL
    GROUP BY hour, service, strategy
    WITH NO DATA
    """)

    # Refresh policy for continuous aggregate
    execute("""
    SELECT add_continuous_aggregate_policy(
      'deployment_success_rate_hourly',
      start_offset => INTERVAL '3 hours',
      end_offset => INTERVAL '1 hour',
      schedule_interval => INTERVAL '1 hour'
    )
    """)
  end

  def down do
    execute("DROP MATERIALIZED VIEW IF EXISTS deployment_success_rate_hourly")
    execute("DROP MATERIALIZED VIEW IF EXISTS deployment_dashboard")

    execute("DROP TRIGGER IF EXISTS trigger_update_deployment_progress ON deployment_replicas")
    execute("DROP FUNCTION IF EXISTS update_deployment_progress()")

    drop(table(:deployment_hooks))
    drop(table(:canary_analysis_results))
    drop(table(:deployment_metrics))
    drop(table(:deployment_events))
    drop(table(:traffic_routes))
    drop(table(:deployment_replicas))
    drop(table(:deployment_revisions))
    drop(table(:deployments))

    execute("DROP TYPE IF EXISTS health_status")
    execute("DROP TYPE IF EXISTS traffic_split_type")
    execute("DROP TYPE IF EXISTS deployment_phase")
    execute("DROP TYPE IF EXISTS deployment_status")
    execute("DROP TYPE IF EXISTS deployment_strategy")
  end
end
