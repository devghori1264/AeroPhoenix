defmodule Orchestrator.Repo.Migrations.CreateCostAnalytics do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    execute("CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE")
    create_resource_type_enum()
    create_aggregation_level_enum()
    create_optimization_status_enum()
    create_resource_usage_table()
    create_usage_aggregates_table()
    create_cost_pricing_table()
    create_rightsizing_recommendations_table()
    create_idle_resources_table()
    create_budgets_table()
    create_budget_alerts_table()
    create_cost_allocation_tags_table()
    create_optimization_policies_table()
    create_cost_reports_table()
    create_indexes()
    create_materialized_views()
    create_cost_functions()
    create_aggregation_triggers()
    enable_timescaledb_hypertables()
  end

  def down do
    execute("DROP MATERIALIZED VIEW IF EXISTS mv_daily_cost_summary CASCADE")
    execute("DROP MATERIALIZED VIEW IF EXISTS mv_resource_utilization CASCADE")
    drop(table(:cost_reports))
    drop(table(:optimization_policies))
    drop(table(:cost_allocation_tags))
    drop(table(:budget_alerts))
    drop(table(:budgets))
    drop(table(:idle_resources))
    drop(table(:rightsizing_recommendations))
    drop(table(:cost_pricing))
    drop(table(:usage_aggregates))
    drop(table(:resource_usage))
    execute("DROP TYPE IF EXISTS optimization_status")
    execute("DROP TYPE IF EXISTS aggregation_level")
    execute("DROP TYPE IF EXISTS resource_type")
  end

  defp create_resource_type_enum do
    execute("""
    CREATE TYPE resource_type AS ENUM (
      'cpu',              -- CPU cores
      'memory',           -- RAM in MB
      'storage',          -- Disk in GB
      'network_ingress',  -- Network in (GB)
      'network_egress',   -- Network out (GB)
      'iops_read',        -- Disk read IOPS
      'iops_write',       -- Disk write IOPS
      'requests',         -- HTTP requests
      'compute_time'      -- Billable compute seconds
    )
    """)
  end

  defp create_aggregation_level_enum do
    execute("""
    CREATE TYPE aggregation_level AS ENUM (
      'raw',      -- Per-minute metrics
      'hourly',   -- 1-hour aggregates
      'daily',    -- 24-hour aggregates
      'weekly',   -- 7-day aggregates
      'monthly'   -- 30-day aggregates
    )
    """)
  end

  defp create_optimization_status_enum do
    execute("""
    CREATE TYPE optimization_status AS ENUM (
      'pending',      -- Recommendation not yet acted upon
      'approved',     -- Approved for implementation
      'rejected',     -- Rejected by user
      'implemented',  -- Successfully applied
      'failed',       -- Implementation failed
      'expired'       -- No longer relevant
    )
    """)
  end

  defp create_resource_usage_table do
    create table(:resource_usage, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:machine_id, :uuid, null: false)
      add(:region, :string, null: false)
      add(:measured_at, :utc_datetime_usec, null: false)
      add(:metrics, :map, null: false)
      add(:cpu_percent, :float)
      add(:memory_mb, :float)
      add(:storage_gb, :float)
      add(:network_ingress_gb, :float)
      add(:network_egress_gb, :float)
      add(:iops_read, :integer)
      add(:iops_write, :integer)
      add(:request_count, :integer)
      add(:cpu_idle_percent, :float)
      add(:memory_free_mb, :float)
      add(:is_idle, :boolean, default: false)
      add(:tags, {:array, :string}, default: [])
      add(:cost_center, :string)
      add(:environment, :string)
      add(:metadata, :map, default: %{})
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute("""
    CREATE INDEX resource_usage_measured_at_idx
    ON resource_usage (measured_at DESC)
    """)
  end

  defp create_usage_aggregates_table do
    create table(:usage_aggregates, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:machine_id, :uuid, null: false)
      add(:region, :string, null: false)
      add(:aggregation_level, :aggregation_level, null: false)
      add(:period_start, :utc_datetime_usec, null: false)
      add(:period_end, :utc_datetime_usec, null: false)
      add(:cpu_min, :float)
      add(:cpu_max, :float)
      add(:cpu_avg, :float)
      add(:cpu_p50, :float)
      add(:cpu_p95, :float)
      add(:cpu_p99, :float)
      add(:memory_min, :float)
      add(:memory_max, :float)
      add(:memory_avg, :float)
      add(:memory_p50, :float)
      add(:memory_p95, :float)
      add(:memory_p99, :float)
      add(:storage_min, :float)
      add(:storage_max, :float)
      add(:storage_avg, :float)
      add(:network_ingress_total, :float)
      add(:network_egress_total, :float)
      add(:iops_read_total, :bigint)
      add(:iops_write_total, :bigint)
      add(:request_count_total, :bigint)
      add(:uptime_seconds, :integer)
      add(:idle_seconds, :integer)
      add(:idle_percentage, :float)
      add(:sample_count, :integer, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      unique_index(:usage_aggregates, [:machine_id, :aggregation_level, :period_start],
        name: :usage_aggregates_unique_period_idx
      )
    )
  end

  defp create_cost_pricing_table do
    create table(:cost_pricing) do
      add(:region, :string, null: false)
      add(:resource_type, :resource_type, null: false)
      add(:unit_price, :decimal, precision: 10, scale: 6, null: false)
      add(:currency, :string, default: "USD")
      add(:tier_min, :float)
      add(:tier_max, :float)
      add(:tier_discount_percent, :float, default: 0.0)
      add(:reserved_1yr_discount, :float)
      add(:reserved_3yr_discount, :float)
      add(:spot_price, :decimal, precision: 10, scale: 6)
      add(:spot_availability, :float)
      add(:effective_from, :utc_datetime)
      add(:effective_until, :utc_datetime)
      add(:metadata, :map, default: %{})
      timestamps()
    end

    create(
      unique_index(:cost_pricing, [:region, :resource_type, :effective_from],
        name: :cost_pricing_unique_idx
      )
    )
  end

  defp create_rightsizing_recommendations_table do
    create table(:rightsizing_recommendations, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:machine_id, :uuid, null: false)
      add(:region, :string, null: false)
      add(:current_cpu, :integer, null: false)
      add(:current_memory_mb, :integer, null: false)
      add(:current_storage_gb, :integer)
      add(:recommended_cpu, :integer, null: false)
      add(:recommended_memory_mb, :integer, null: false)
      add(:recommended_storage_gb, :integer)
      add(:cpu_p95_utilization, :float)
      add(:memory_p95_utilization, :float)
      add(:analysis_period_days, :integer, default: 7)
      add(:current_monthly_cost, :decimal, precision: 10, scale: 2)
      add(:recommended_monthly_cost, :decimal, precision: 10, scale: 2)
      add(:monthly_savings, :decimal, precision: 10, scale: 2)
      add(:annual_savings, :decimal, precision: 10, scale: 2)
      add(:savings_percent, :float)
      add(:confidence_score, :float)
      add(:risk_level, :string)
      add(:status, :optimization_status, default: "pending")
      add(:reason, :text)
      add(:approved_by, :string)
      add(:approved_at, :utc_datetime)
      add(:implemented_at, :utc_datetime)
      add(:expires_at, :utc_datetime)
      add(:metadata, :map, default: %{})
      timestamps()
    end
  end

  defp create_idle_resources_table do
    create table(:idle_resources, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:machine_id, :uuid, null: false)
      add(:region, :string, null: false)
      add(:first_detected_at, :utc_datetime_usec, null: false)
      add(:last_checked_at, :utc_datetime_usec, null: false)
      add(:idle_duration_hours, :float, null: false)
      add(:avg_cpu_percent, :float)
      add(:avg_memory_percent, :float)
      add(:avg_network_kb, :float)
      add(:request_count, :integer, default: 0)
      add(:daily_cost, :decimal, precision: 10, scale: 2)
      add(:wasted_cost, :decimal, precision: 10, scale: 2)
      add(:idle_threshold_cpu, :float, default: 5.0)
      add(:idle_threshold_memory, :float, default: 20.0)
      add(:idle_threshold_network, :float, default: 1.0)
      add(:is_active, :boolean, default: true)
      add(:resolved_at, :utc_datetime)
      add(:resolution_action, :string)
      add(:metadata, :map, default: %{})
      timestamps()
    end
  end

  defp create_budgets_table do
    create table(:budgets) do
      add(:name, :string, null: false)
      add(:description, :text)
      add(:scope_type, :string, null: false)
      add(:scope_value, :string)
      add(:tags, {:array, :string}, default: [])
      add(:monthly_limit, :decimal, precision: 12, scale: 2, null: false)
      add(:daily_limit, :decimal, precision: 12, scale: 2)
      add(:currency, :string, default: "USD")
      add(:warning_threshold, :integer, default: 80)
      add(:critical_threshold, :integer, default: 95)
      add(:current_month_spend, :decimal, precision: 12, scale: 2, default: 0)
      add(:current_day_spend, :decimal, precision: 12, scale: 2, default: 0)
      add(:projected_month_spend, :decimal, precision: 12, scale: 2)
      add(:start_date, :date, null: false)
      add(:end_date, :date)
      add(:is_active, :boolean, default: true)
      add(:last_alert_sent_at, :utc_datetime)
      add(:metadata, :map, default: %{})
      timestamps()
    end
  end

  defp create_budget_alerts_table do
    create table(:budget_alerts, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:budget_id, references(:budgets, on_delete: :delete_all), null: false)
      add(:alert_type, :string, null: false)
      add(:severity, :string, null: false)
      add(:threshold_percent, :integer, null: false)
      add(:current_spend, :decimal, precision: 12, scale: 2, null: false)
      add(:budget_limit, :decimal, precision: 12, scale: 2, null: false)
      add(:percent_used, :float, null: false)
      add(:projected_spend, :decimal, precision: 12, scale: 2)
      add(:projected_overage, :decimal, precision: 12, scale: 2)
      add(:days_until_exceeded, :integer)
      add(:notified_at, :utc_datetime)
      add(:notification_channels, {:array, :string}, default: [])
      add(:acknowledged_at, :utc_datetime)
      add(:acknowledged_by, :string)
      add(:message, :text)
      add(:metadata, :map, default: %{})
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  defp create_cost_allocation_tags_table do
    create table(:cost_allocation_tags) do
      add(:tag_key, :string, null: false)
      add(:tag_value, :string, null: false)
      add(:machine_id, :uuid, null: false)
      add(:cost_center, :string)
      add(:department, :string)
      add(:project, :string)
      add(:environment, :string)
      add(:owner, :string)
      add(:valid_from, :utc_datetime, null: false)
      add(:valid_until, :utc_datetime)
      timestamps()
    end

    create(
      unique_index(:cost_allocation_tags, [:machine_id, :tag_key, :valid_from],
        name: :cost_allocation_tags_unique_idx
      )
    )
  end

  defp create_optimization_policies_table do
    create table(:optimization_policies) do
      add(:name, :string, null: false)
      add(:description, :text)
      add(:policy_type, :string, null: false)
      add(:conditions, :map, null: false)
      add(:actions, {:array, :string}, null: false)
      add(:enabled, :boolean, default: true)
      add(:dry_run, :boolean, default: true)
      add(:priority, :integer, default: 100)
      add(:cooldown_minutes, :integer, default: 60)
      add(:max_executions_per_hour, :integer)
      add(:max_executions_per_day, :integer)
      add(:scope_tags, {:array, :string}, default: [])
      add(:scope_regions, {:array, :string}, default: [])
      add(:last_executed_at, :utc_datetime)
      add(:total_executions, :integer, default: 0)
      add(:successful_executions, :integer, default: 0)
      add(:failed_executions, :integer, default: 0)
      add(:total_savings, :decimal, precision: 12, scale: 2, default: 0)
      add(:metadata, :map, default: %{})
      timestamps()
    end
  end

  defp create_cost_reports_table do
    create table(:cost_reports, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:report_type, :string, null: false)
      add(:report_name, :string, null: false)
      add(:period_start, :utc_datetime, null: false)
      add(:period_end, :utc_datetime, null: false)
      add(:scope_type, :string)
      add(:scope_value, :string)
      add(:tags, {:array, :string}, default: [])
      add(:total_cost, :decimal, precision: 12, scale: 2, null: false)
      add(:compute_cost, :decimal, precision: 12, scale: 2)
      add(:storage_cost, :decimal, precision: 12, scale: 2)
      add(:network_cost, :decimal, precision: 12, scale: 2)
      add(:cost_by_region, :map)
      add(:cost_by_machine, :map)
      add(:cost_by_tag, :map)
      add(:cost_by_resource_type, :map)
      add(:trend_7d, :float)
      add(:trend_30d, :float)
      add(:forecast_7d, :decimal, precision: 12, scale: 2)
      add(:forecast_30d, :decimal, precision: 12, scale: 2)
      add(:idle_cost, :decimal, precision: 12, scale: 2)
      add(:rightsizing_savings, :decimal, precision: 12, scale: 2)
      add(:total_savings_potential, :decimal, precision: 12, scale: 2)
      add(:optimization_score, :float)
      add(:report_data, :map)
      add(:generated_at, :utc_datetime, null: false)
      add(:generated_by, :string)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  defp create_indexes do
    create(index(:resource_usage, [:machine_id, :measured_at]))
    create(index(:resource_usage, [:region, :measured_at]))
    create(index(:resource_usage, [:is_idle]))
    create(index(:resource_usage, [:tags], using: :gin))
    create(index(:usage_aggregates, [:machine_id, :aggregation_level, :period_start]))
    create(index(:usage_aggregates, [:region, :aggregation_level, :period_start]))
    create(index(:cost_pricing, [:region, :resource_type, :effective_from]))
    create(index(:rightsizing_recommendations, [:machine_id, :status]))
    create(index(:rightsizing_recommendations, [:status, :expires_at]))
    create(index(:rightsizing_recommendations, [:monthly_savings]))
    create(index(:idle_resources, [:machine_id, :is_active]))
    create(index(:idle_resources, [:is_active, :idle_duration_hours]))
    create(index(:idle_resources, [:first_detected_at]))
    create(index(:budgets, [:is_active, :start_date]))
    create(index(:budgets, [:scope_type, :scope_value]))
    create(index(:budget_alerts, [:budget_id, :severity]))
    create(index(:budget_alerts, [:notified_at]))
    create(index(:cost_allocation_tags, [:machine_id, :valid_from]))
    create(index(:cost_allocation_tags, [:tag_key, :tag_value]))
    create(index(:cost_allocation_tags, [:cost_center]))
    create(index(:optimization_policies, [:enabled, :dry_run]))
    create(index(:optimization_policies, [:policy_type]))
    create(index(:cost_reports, [:report_type, :period_start]))
    create(index(:cost_reports, [:scope_type, :scope_value]))
    create(index(:cost_reports, [:generated_at]))
  end

  defp create_materialized_views do
    execute("""
    CREATE MATERIALIZED VIEW mv_daily_cost_summary AS
    SELECT
      date_trunc('day', ru.measured_at) AS cost_date,
      ru.region,
      COUNT(DISTINCT ru.machine_id) AS machine_count,
      AVG(ru.cpu_percent) AS avg_cpu,
      AVG(ru.memory_mb) AS avg_memory,
      SUM(ru.network_ingress_gb + ru.network_egress_gb) AS total_network_gb,
      COUNT(*) FILTER (WHERE ru.is_idle = true) AS idle_count,
      COUNT(*) AS sample_count
    FROM resource_usage ru
    GROUP BY date_trunc('day', ru.measured_at), ru.region
    """)

    create(unique_index(:mv_daily_cost_summary, [:cost_date, :region]))

    execute("""
    CREATE MATERIALIZED VIEW mv_resource_utilization AS
    SELECT
      machine_id,
      region,
      MAX(measured_at) AS last_measured,
      AVG(cpu_percent) AS avg_cpu,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY cpu_percent) AS p95_cpu,
      AVG(memory_mb) AS avg_memory,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY memory_mb) AS p95_memory,
      AVG(CASE WHEN is_idle THEN 1 ELSE 0 END) * 100 AS idle_percentage,
      COUNT(*) AS sample_count
    FROM resource_usage
    WHERE measured_at > NOW() - INTERVAL '7 days'
    GROUP BY machine_id, region
    """)

    create(unique_index(:mv_resource_utilization, [:machine_id]))
  end

  defp create_cost_functions do
    execute("""
    CREATE OR REPLACE FUNCTION calculate_resource_cost(
      p_region TEXT,
      p_resource_type resource_type,
      p_usage NUMERIC,
      p_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    ) RETURNS NUMERIC AS $$
    DECLARE
      v_unit_price NUMERIC;
      v_discount NUMERIC := 0;
    BEGIN
      SELECT unit_price INTO v_unit_price
      FROM cost_pricing
      WHERE region = p_region
        AND resource_type = p_resource_type
        AND p_timestamp >= effective_from
        AND (effective_until IS NULL OR p_timestamp < effective_until)
      ORDER BY effective_from DESC
      LIMIT 1;
      IF v_unit_price IS NULL THEN
        RETURN 0;
      END IF;
      RETURN p_usage * v_unit_price * (1 - v_discount);
    END;
    $$ LANGUAGE plpgsql STABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION detect_idle_resources(
      p_lookback_hours INTEGER DEFAULT 24,
      p_cpu_threshold FLOAT DEFAULT 5.0,
      p_memory_threshold FLOAT DEFAULT 20.0
    ) RETURNS TABLE(
      machine_id UUID,
      avg_cpu FLOAT,
      avg_memory FLOAT,
      idle_hours FLOAT
    ) AS $$
    BEGIN
      RETURN QUERY
      SELECT
        ru.machine_id,
        AVG(ru.cpu_percent) AS avg_cpu,
        AVG((ru.memory_mb / NULLIF(ru.memory_mb + ru.memory_free_mb, 0)) * 100) AS avg_memory,
        EXTRACT(EPOCH FROM (MAX(ru.measured_at) - MIN(ru.measured_at))) / 3600 AS idle_hours
      FROM resource_usage ru
      WHERE ru.measured_at > NOW() - (p_lookback_hours || ' hours')::INTERVAL
      GROUP BY ru.machine_id
      HAVING
        AVG(ru.cpu_percent) < p_cpu_threshold
        AND AVG((ru.memory_mb / NULLIF(ru.memory_mb + ru.memory_free_mb, 0)) * 100) < p_memory_threshold;
    END;
    $$ LANGUAGE plpgsql STABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION refresh_cost_analytics_views()
    RETURNS void AS $$
    BEGIN
      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_cost_summary;
      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_resource_utilization;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  defp create_aggregation_triggers do
    execute("""
    CREATE OR REPLACE FUNCTION mark_idle_resource()
    RETURNS TRIGGER AS $$
    BEGIN
      NEW.is_idle := (
        NEW.cpu_percent < 5.0
        AND (NEW.memory_mb / NULLIF(NEW.memory_mb + NEW.memory_free_mb, 0) * 100) < 20.0
        AND COALESCE(NEW.request_count, 0) = 0
      );
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER trigger_mark_idle_resource
    BEFORE INSERT ON resource_usage
    FOR EACH ROW
    EXECUTE FUNCTION mark_idle_resource();
    """)
  end

  defp enable_timescaledb_hypertables do
    execute("""
    SELECT create_hypertable(
      'resource_usage',
      'measured_at',
      chunk_time_interval => INTERVAL '1 day',
      if_not_exists => TRUE
    )
    """)

    execute("""
    ALTER TABLE resource_usage SET (
      timescaledb.compress,
      timescaledb.compress_segmentby = 'machine_id,region'
    )
    """)

    execute("""
    SELECT add_compression_policy('resource_usage', INTERVAL '7 days')
    """)

    execute("""
    SELECT add_retention_policy('resource_usage', INTERVAL '90 days')
    """)
  end
end
