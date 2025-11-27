defmodule Orchestrator.Repo.Migrations.CreatePerformanceMetrics do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE")
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    execute("CREATE EXTENSION IF NOT EXISTS btree_gin")

    execute("""
    CREATE TYPE metric_type AS ENUM (
      'counter',           -- Monotonically increasing value (requests, errors)
      'gauge',             -- Point-in-time value (CPU, memory, connections)
      'histogram',         -- Distribution of values (latency, size)
      'summary'            -- Pre-calculated statistics (p50, p95, p99)
    )
    """)

    execute("""
    CREATE TYPE metric_unit AS ENUM (
      'none',              -- Unitless (count, ratio)
      'percent',           -- Percentage (0-100)
      'bytes',             -- Storage size
      'milliseconds',      -- Time duration
      'seconds',           -- Time duration
      'requests_per_sec',  -- Rate
      'ops_per_sec'        -- Operations rate
    )
    """)

    execute("""
    CREATE TYPE alert_severity AS ENUM (
      'info',
      'warning',
      'critical'
    )
    """)

    execute("""
    CREATE TYPE alert_state AS ENUM (
      'pending',          -- Alert condition met, waiting for duration
      'firing',           -- Alert actively firing
      'resolved',         -- Alert condition no longer met
      'silenced',         -- Alert silenced by user
      'acked'             -- Alert acknowledged
    )
    """)

    execute("""
    CREATE TYPE aggregation_function AS ENUM (
      'avg',
      'sum',
      'min',
      'max',
      'count',
      'p50',
      'p90',
      'p95',
      'p99',
      'stddev',
      'rate'
    )
    """)

    execute("""
    CREATE TYPE sla_status AS ENUM (
      'meeting',          -- Currently meeting SLA
      'at_risk',          -- Close to violation
      'violated',         -- SLA violated
      'recovering'        -- Recovering from violation
    )
    """)

    create table(:metric_definitions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false, comment: "Metric name (e.g., http_requests_total)")
      add(:type, :metric_type, null: false)
      add(:unit, :metric_unit, null: false, default: "none")
      add(:help, :text, comment: "Human-readable description")
      add(:namespace, :string, comment: "Metric namespace (e.g., orchestrator, machine)")
      add(:subsystem, :string, comment: "Subsystem name (e.g., api, database)")
      add(:label_keys, {:array, :string}, default: [], comment: "Valid label keys")
      add(:cardinality, :integer, default: 0, comment: "Number of unique time series")
      add(:retention_days, :integer, default: 90)
      add(:compression_enabled, :boolean, default: true)
      add(:compress_after_hours, :integer, default: 1)
      add(:enabled, :boolean, default: true)
      add(:created_by, :uuid, comment: "User who created this metric")
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:metric_definitions, [:name]))
    create(index(:metric_definitions, [:namespace, :subsystem]))
    create(index(:metric_definitions, [:type]))
    create(index(:metric_definitions, [:enabled]))

    create table(:metric_samples, primary_key: false) do
      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:timestamp, :utc_datetime_usec, null: false, comment: "Sample timestamp")
      add(:labels, :jsonb, default: "{}", comment: "Label key-value pairs")
      add(:labels_hash, :string, comment: "Hash of labels for fast lookups")
      add(:value, :float, null: false, comment: "Metric value")
      add(:bucket_values, :jsonb, comment: "Histogram bucket counts")
      add(:quantile_values, :jsonb, comment: "Summary quantile values")
      add(:count, :bigint, comment: "Sample count (histogram/summary)")
      add(:sum, :float, comment: "Sum of values (histogram/summary)")
      add(:machine_id, :uuid, comment: "Source machine ID")
      add(:region, :string, comment: "Source region")
    end

    execute("""
    SELECT create_hypertable(
      'metric_samples',
      'timestamp',
      chunk_time_interval => INTERVAL '1 hour',
      if_not_exists => TRUE
    )
    """)

    create(index(:metric_samples, [:metric_id, :timestamp]))
    create(index(:metric_samples, [:labels_hash]))
    create(index(:metric_samples, [:machine_id]))
    create(index(:metric_samples, [:region]))
    execute("CREATE INDEX metric_samples_labels_gin ON metric_samples USING GIN (labels)")

    execute("""
    SELECT add_compression_policy(
      'metric_samples',
      INTERVAL '1 hour',
      if_not_exists => TRUE
    )
    """)

    execute("""
    SELECT add_retention_policy(
      'metric_samples',
      INTERVAL '90 days',
      if_not_exists => TRUE
    )
    """)

    create table(:metric_aggregates, primary_key: false) do
      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:timestamp, :utc_datetime_usec, null: false)
      add(:interval, :string, null: false, comment: "1m, 5m, 1h, 1d, 1w")
      add(:labels, :jsonb, default: "{}")
      add(:labels_hash, :string)
      add(:avg, :float)
      add(:sum, :float)
      add(:min, :float)
      add(:max, :float)
      add(:count, :bigint)
      add(:stddev, :float)
      add(:p50, :float)
      add(:p90, :float)
      add(:p95, :float)
      add(:p99, :float)
      add(:rate, :float, comment: "Per-second rate")
      add(:machine_id, :uuid)
      add(:region, :string)
    end

    execute("""
    SELECT create_hypertable(
      'metric_aggregates',
      'timestamp',
      chunk_time_interval => INTERVAL '1 day',
      if_not_exists => TRUE
    )
    """)

    create(index(:metric_aggregates, [:metric_id, :interval, :timestamp]))
    create(index(:metric_aggregates, [:labels_hash]))
    execute("CREATE INDEX metric_aggregates_labels_gin ON metric_aggregates USING GIN (labels)")

    execute("""
    SELECT add_compression_policy(
      'metric_aggregates',
      INTERVAL '1 day',
      if_not_exists => TRUE
    )
    """)

    execute("""
    SELECT add_retention_policy(
      'metric_aggregates',
      INTERVAL '365 days',
      if_not_exists => TRUE
    )
    """)

    create table(:alert_rules) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:severity, :alert_severity, null: false)
      add(:enabled, :boolean, default: true)
      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all))
      add(:query, :text, null: false, comment: "PromQL-style query")
      add(:condition, :string, null: false, comment: ">, <, ==, !=, >=, <=")
      add(:threshold, :float, null: false)
      add(:duration_seconds, :integer, default: 60, comment: "How long condition must be true")
      add(:label_matchers, :jsonb, default: "{}", comment: "Label filters")
      add(:description, :text)
      add(:summary, :text)
      add(:runbook_url, :string, comment: "Link to runbook/docs")
      add(:notification_channels, {:array, :string}, default: ["email"])
      add(:evaluation_interval_seconds, :integer, default: 60)
      add(:last_evaluated_at, :utc_datetime_usec)
      add(:last_state, :alert_state)
      add(:created_by, :uuid)
      add(:team, :string)
      add(:priority, :integer, default: 0)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:alert_rules, [:name]))
    create(index(:alert_rules, [:enabled]))
    create(index(:alert_rules, [:severity]))
    create(index(:alert_rules, [:metric_id]))
    create(index(:alert_rules, [:team]))

    create table(:alert_instances) do
      add(:id, :uuid, primary_key: true)

      add(:alert_rule_id, references(:alert_rules, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:state, :alert_state, null: false, default: "pending")
      add(:severity, :alert_severity, null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:resolved_at, :utc_datetime_usec)
      add(:silenced_until, :utc_datetime_usec)
      add(:labels, :jsonb, default: "{}", comment: "Labels that triggered this alert")
      add(:current_value, :float, comment: "Current metric value")
      add(:threshold, :float, comment: "Threshold that was crossed")
      add(:description, :text)
      add(:summary, :text)
      add(:runbook_url, :string)
      add(:acknowledged_at, :utc_datetime_usec)
      add(:acknowledged_by, :uuid)
      add(:notified_at, :utc_datetime_usec)
      add(:notification_count, :integer, default: 0)
      add(:notification_channels, {:array, :string}, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:alert_instances, [:alert_rule_id]))
    create(index(:alert_instances, [:state]))
    create(index(:alert_instances, [:started_at]))
    create(index(:alert_instances, [:severity]))
    execute("CREATE INDEX alert_instances_labels_gin ON alert_instances USING GIN (labels)")

    create table(:sla_definitions) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all))
      add(:target_value, :float, null: false, comment: "SLA target (e.g., 99.9 for uptime)")
      add(:comparison, :string, null: false, comment: ">=, <=, ==, etc.")
      add(:window_days, :integer, default: 30, comment: "Rolling window in days")
      add(:error_budget_percent, :float, comment: "Allowed error percentage")
      add(:current_value, :float)
      add(:status, :sla_status, default: "meeting")
      add(:last_violation_at, :utc_datetime_usec)
      add(:violation_count, :integer, default: 0)
      add(:service, :string, null: false)
      add(:team, :string)
      add(:enabled, :boolean, default: true)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sla_definitions, [:name]))
    create(index(:sla_definitions, [:service]))
    create(index(:sla_definitions, [:status]))
    create(index(:sla_definitions, [:enabled]))

    create table(:sla_violations) do
      add(:id, :uuid, primary_key: true)
      add(:sla_id, references(:sla_definitions, type: :uuid, on_delete: :delete_all), null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      add(:duration_seconds, :integer)
      add(:target_value, :float)
      add(:actual_value, :float)
      add(:deviation_percent, :float)
      add(:error_budget_consumed, :float, comment: "Percentage of error budget consumed")
      add(:description, :text)
      add(:root_cause, :text)
      add(:remediation, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sla_violations, [:sla_id]))
    create(index(:sla_violations, [:started_at]))

    create table(:dashboards) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:layout, :jsonb, default: "{}", comment: "Grid layout configuration")
      add(:refresh_interval_seconds, :integer, default: 30)
      add(:is_public, :boolean, default: false)
      add(:team, :string)
      add(:created_by, :uuid)
      add(:tags, {:array, :string}, default: [])
      add(:starred, :boolean, default: false)
      add(:view_count, :integer, default: 0)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:dashboards, [:name]))
    create(index(:dashboards, [:team]))
    create(index(:dashboards, [:starred]))
    execute("CREATE INDEX dashboards_tags_gin ON dashboards USING GIN (tags)")

    create table(:dashboard_panels) do
      add(:id, :uuid, primary_key: true)

      add(:dashboard_id, references(:dashboards, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:title, :string, null: false)
      add(:description, :text)

      add(:panel_type, :string,
        null: false,
        comment: "graph, stat, table, heatmap, gauge, pie"
      )

      add(:query, :text, null: false, comment: "Metric query (PromQL-style)")
      add(:visualization_config, :jsonb, default: "{}", comment: "Chart-specific config")
      add(:grid_x, :integer, default: 0)
      add(:grid_y, :integer, default: 0)
      add(:grid_width, :integer, default: 12)
      add(:grid_height, :integer, default: 8)
      add(:time_range_from, :string, default: "now-1h")
      add(:time_range_to, :string, default: "now")
      add(:legend_enabled, :boolean, default: true)
      add(:threshold_lines, :jsonb, comment: "Warning/critical thresholds")
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:dashboard_panels, [:dashboard_id]))

    create table(:anomaly_models) do
      add(:id, :uuid, primary_key: true)

      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:algorithm, :string, null: false, comment: "zscore, isolation_forest, prophet, etc.")
      add(:parameters, :jsonb, default: "{}")
      add(:sensitivity, :float, default: 0.95, comment: "Detection sensitivity (0-1)")
      add(:training_data_days, :integer, default: 14)
      add(:last_trained_at, :utc_datetime_usec)
      add(:model_accuracy, :float, comment: "Model accuracy score")
      add(:enabled, :boolean, default: true)
      add(:model_data, :bytea, comment: "Serialized model")
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:anomaly_models, [:metric_id, :name]))
    create(index(:anomaly_models, [:enabled]))

    create table(:anomalies) do
      add(:id, :uuid, primary_key: true)

      add(:model_id, references(:anomaly_models, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:detected_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      add(:severity, :alert_severity, default: "warning")
      add(:anomaly_score, :float, null: false, comment: "How anomalous (0-1)")
      add(:expected_value, :float)
      add(:actual_value, :float)
      add(:deviation_percent, :float)
      add(:labels, :jsonb, default: "{}")
      add(:description, :text)
      add(:is_false_positive, :boolean, default: false)
      add(:investigated_at, :utc_datetime_usec)
      add(:investigated_by, :uuid)
      add(:root_cause, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:anomalies, [:model_id]))
    create(index(:anomalies, [:metric_id]))
    create(index(:anomalies, [:detected_at]))
    create(index(:anomalies, [:severity]))
    create(index(:anomalies, [:is_false_positive]))

    create table(:traces) do
      add(:id, :uuid, primary_key: true)
      add(:trace_id, :string, null: false, comment: "Distributed trace ID")
      add(:started_at, :utc_datetime_usec, null: false)
      add(:duration_ms, :float)
      add(:service, :string, null: false)
      add(:operation, :string, null: false)
      add(:status, :string, comment: "ok, error, timeout")
      add(:error_message, :text)
      add(:span_count, :integer, default: 0)
      add(:tags, :jsonb, default: "{}")
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:traces, [:trace_id]))
    create(index(:traces, [:service]))
    create(index(:traces, [:started_at]))
    create(index(:traces, [:status]))
    execute("CREATE INDEX traces_tags_gin ON traces USING GIN (tags)")

    create table(:spans) do
      add(:id, :uuid, primary_key: true)
      add(:trace_id, references(:traces, type: :uuid, on_delete: :delete_all), null: false)
      add(:span_id, :string, null: false)
      add(:parent_span_id, :string)
      add(:service, :string, null: false)
      add(:operation, :string, null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:duration_ms, :float, null: false)
      add(:tags, :jsonb, default: "{}")
      add(:logs, :jsonb, default: "[]", comment: "Structured log entries")
      add(:status, :string)
      add(:error, :boolean, default: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:spans, [:trace_id]))
    create(index(:spans, [:span_id]))
    create(index(:spans, [:service]))
    create(index(:spans, [:started_at]))
    execute("CREATE INDEX spans_tags_gin ON spans USING GIN (tags)")

    execute("""
    CREATE MATERIALIZED VIEW mv_metrics_realtime AS
    SELECT
      m.name,
      m.namespace,
      m.subsystem,
      m.type,
      s.labels,
      s.region,
      AVG(s.value) as avg_value,
      MAX(s.value) as max_value,
      MIN(s.value) as min_value,
      COUNT(*) as sample_count,
      MAX(s.timestamp) as last_updated
    FROM metric_samples s
    JOIN metric_definitions m ON m.id = s.metric_id
    WHERE s.timestamp >= NOW() - INTERVAL '5 minutes'
    GROUP BY m.name, m.namespace, m.subsystem, m.type, s.labels, s.region
    """)

    create(index(:mv_metrics_realtime, [:name]))
    create(index(:mv_metrics_realtime, [:namespace, :subsystem]))

    execute("""
    CREATE MATERIALIZED VIEW mv_sla_compliance AS
    SELECT
      s.id,
      s.name,
      s.service,
      s.team,
      s.status,
      s.current_value,
      s.target_value,
      s.error_budget_percent,
      COUNT(v.id) as violation_count,
      MAX(v.started_at) as last_violation,
      (s.error_budget_percent - COALESCE(SUM(v.error_budget_consumed), 0)) as remaining_error_budget
    FROM sla_definitions s
    LEFT JOIN sla_violations v ON v.sla_id = s.id
      AND v.started_at >= NOW() - (s.window_days || ' days')::INTERVAL
    WHERE s.enabled = true
    GROUP BY s.id, s.name, s.service, s.team, s.status, s.current_value, s.target_value, s.error_budget_percent
    """)

    create(index(:mv_sla_compliance, [:service]))
    create(index(:mv_sla_compliance, [:status]))

    execute("""
    CREATE MATERIALIZED VIEW mv_active_alerts AS
    SELECT
      r.id as rule_id,
      r.name as rule_name,
      r.severity,
      r.team,
      COUNT(i.id) FILTER (WHERE i.state = 'firing') as firing_count,
      COUNT(i.id) FILTER (WHERE i.state = 'pending') as pending_count,
      MAX(i.started_at) FILTER (WHERE i.state = 'firing') as last_fired,
      SUM(i.notification_count) as total_notifications
    FROM alert_rules r
    LEFT JOIN alert_instances i ON i.alert_rule_id = r.id
      AND i.started_at >= NOW() - INTERVAL '24 hours'
    WHERE r.enabled = true
    GROUP BY r.id, r.name, r.severity, r.team
    """)

    create(index(:mv_active_alerts, [:severity]))
    create(index(:mv_active_alerts, [:team]))

    execute("""
    CREATE OR REPLACE FUNCTION calculate_sla_compliance(
      p_sla_id UUID,
      p_window_days INTEGER DEFAULT 30
    )
    RETURNS TABLE (
      current_value FLOAT,
      target_value FLOAT,
      compliance_percent FLOAT,
      error_budget_remaining FLOAT,
      status sla_status
    ) AS $$
    DECLARE
      v_sla RECORD;
      v_metric_value FLOAT;
      v_compliance FLOAT;
      v_budget FLOAT;
      v_status sla_status;
    BEGIN
      -- Get SLA definition
      SELECT * INTO v_sla FROM sla_definitions WHERE id = p_sla_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'SLA not found: %', p_sla_id;
      END IF;
      -- Calculate current metric value over window
      SELECT AVG(avg) INTO v_metric_value
      FROM metric_aggregates
      WHERE metric_id = v_sla.metric_id
        AND interval = '1h'
        AND timestamp >= NOW() - (p_window_days || ' days')::INTERVAL;
      -- Calculate compliance percentage
      v_compliance := (v_metric_value / v_sla.target_value) * 100;
      -- Calculate remaining error budget
      SELECT v_sla.error_budget_percent - COALESCE(SUM(error_budget_consumed), 0)
      INTO v_budget
      FROM sla_violations
      WHERE sla_id = p_sla_id
        AND started_at >= NOW() - (p_window_days || ' days')::INTERVAL;
      -- Determine status
      IF v_compliance >= 100 THEN
        v_status := 'meeting';
      ELSIF v_budget < 10 THEN
        v_status := 'at_risk';
      ELSIF v_compliance < 95 THEN
        v_status := 'violated';
      ELSE
        v_status := 'recovering';
      END IF;
      RETURN QUERY SELECT v_metric_value, v_sla.target_value, v_compliance, v_budget, v_status;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION refresh_metrics_views()
    RETURNS void AS $$
    BEGIN
      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_metrics_realtime;
      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sla_compliance;
      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_active_alerts;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION evaluate_alert_rule(p_rule_id UUID)
    RETURNS TABLE (
      should_fire BOOLEAN,
      current_value FLOAT,
      threshold_crossed BOOLEAN
    ) AS $$
    DECLARE
      v_rule RECORD;
      v_current_value FLOAT;
      v_crossed BOOLEAN;
      v_should_fire BOOLEAN;
    BEGIN
      -- Get alert rule
      SELECT * INTO v_rule FROM alert_rules WHERE id = p_rule_id AND enabled = true;
      IF NOT FOUND THEN
        RETURN;
      END IF;
      -- Execute query to get current value
      -- This is simplified - real implementation would parse and execute the query
      SELECT AVG(value) INTO v_current_value
      FROM metric_samples
      WHERE metric_id = v_rule.metric_id
        AND timestamp >= NOW() - (v_rule.duration_seconds || ' seconds')::INTERVAL;
      -- Check if threshold is crossed
      v_crossed := CASE v_rule.condition
        WHEN '>' THEN v_current_value > v_rule.threshold
        WHEN '<' THEN v_current_value < v_rule.threshold
        WHEN '>=' THEN v_current_value >= v_rule.threshold
        WHEN '<=' THEN v_current_value <= v_rule.threshold
        WHEN '==' THEN v_current_value = v_rule.threshold
        WHEN '!=' THEN v_current_value != v_rule.threshold
        ELSE false
      END;
      v_should_fire := v_crossed;
      RETURN QUERY SELECT v_should_fire, v_current_value, v_crossed;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION update_metric_cardinality()
    RETURNS TRIGGER AS $$
    BEGIN
      UPDATE metric_definitions
      SET cardinality = (
        SELECT COUNT(DISTINCT labels_hash)
        FROM metric_samples
        WHERE metric_id = NEW.metric_id
      )
      WHERE id = NEW.metric_id;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER trg_update_cardinality
    AFTER INSERT ON metric_samples
    FOR EACH ROW
    EXECUTE FUNCTION update_metric_cardinality()
    """)

    execute("""
    CREATE MATERIALIZED VIEW metric_aggregates_1m
    WITH (timescaledb.continuous) AS
    SELECT
      metric_id,
      time_bucket('1 minute', timestamp) AS timestamp,
      '1m' as interval,
      labels,
      labels_hash,
      AVG(value) as avg,
      SUM(value) as sum,
      MIN(value) as min,
      MAX(value) as max,
      COUNT(*) as count,
      STDDEV(value) as stddev,
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY value) as p50,
      PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY value) as p90,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY value) as p95,
      PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY value) as p99,
      machine_id,
      region
    FROM metric_samples
    GROUP BY metric_id, time_bucket('1 minute', timestamp), labels, labels_hash, machine_id, region
    """)

    execute("""
    SELECT add_continuous_aggregate_policy(
      'metric_aggregates_1m',
      start_offset => INTERVAL '1 hour',
      end_offset => INTERVAL '1 minute',
      schedule_interval => INTERVAL '1 minute',
      if_not_exists => TRUE
    )
    """)
  end

  def down do
    execute("DROP MATERIALIZED VIEW IF EXISTS metric_aggregates_1m CASCADE")
    execute("DROP MATERIALIZED VIEW IF EXISTS mv_active_alerts CASCADE")
    execute("DROP MATERIALIZED VIEW IF EXISTS mv_sla_compliance CASCADE")
    execute("DROP MATERIALIZED VIEW IF EXISTS mv_metrics_realtime CASCADE")
    execute("DROP FUNCTION IF EXISTS evaluate_alert_rule CASCADE")
    execute("DROP FUNCTION IF EXISTS refresh_metrics_views CASCADE")
    execute("DROP FUNCTION IF EXISTS calculate_sla_compliance CASCADE")
    execute("DROP FUNCTION IF EXISTS update_metric_cardinality CASCADE")
    drop(table(:spans))
    drop(table(:traces))
    drop(table(:anomalies))
    drop(table(:anomaly_models))
    drop(table(:dashboard_panels))
    drop(table(:dashboards))
    drop(table(:sla_violations))
    drop(table(:sla_definitions))
    drop(table(:alert_instances))
    drop(table(:alert_rules))
    drop(table(:metric_aggregates))
    drop(table(:metric_samples))
    drop(table(:metric_definitions))
    execute("DROP TYPE IF EXISTS sla_status")
    execute("DROP TYPE IF EXISTS aggregation_function")
    execute("DROP TYPE IF EXISTS alert_state")
    execute("DROP TYPE IF EXISTS alert_severity")
    execute("DROP TYPE IF EXISTS metric_unit")
    execute("DROP TYPE IF EXISTS metric_type")
  end
end
