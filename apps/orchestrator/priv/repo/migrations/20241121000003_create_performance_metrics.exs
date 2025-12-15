defmodule Orchestrator.Repo.Migrations.CreatePerformanceMetrics do
  use Ecto.Migration

  def up do
    create_metric_definitions_table()
    create_metric_samples_table()
    create_metric_aggregates_table()
    create_alert_rules_table()
    create_alert_instances_table()
    create_sla_definitions_table()
    create_sla_violations_table()
    create_dashboards_table()
    create_dashboard_panels_table()
    create_anomaly_models_table()
    create_anomalies_table()
    create_traces_table()
    create_spans_table()
  end

  def down do
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
  end

  defp create_metric_definitions_table do
    create table(:metric_definitions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:type, :string, null: false)
      add(:unit, :string, null: false, default: "none")
      add(:help, :text)
      add(:namespace, :string)
      add(:subsystem, :string)
      add(:label_keys, {:array, :string}, default: [])
      add(:cardinality, :integer, default: 0)
      add(:retention_days, :integer, default: 90)
      add(:compression_enabled, :boolean, default: true)
      add(:compress_after_hours, :integer, default: 1)
      add(:enabled, :boolean, default: true)
      add(:created_by, :uuid)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:metric_definitions, [:name]))
    create(index(:metric_definitions, [:namespace, :subsystem]))
    create(index(:metric_definitions, [:type]))
    create(index(:metric_definitions, [:enabled]))
  end

  defp create_metric_samples_table do
    create table(:metric_samples, primary_key: false) do
      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:timestamp, :utc_datetime_usec, null: false)
      add(:labels, :map, default: %{})
      add(:labels_hash, :string)
      add(:value, :float, null: false)
      add(:bucket_values, :map)
      add(:quantile_values, :map)
      add(:count, :bigint)
      add(:sum, :float)
      add(:machine_id, :uuid)
      add(:region, :string)
    end
  end

  defp create_metric_aggregates_table do
    create table(:metric_aggregates, primary_key: false) do
      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:timestamp, :utc_datetime_usec, null: false)
      add(:interval, :string, null: false)
      add(:labels, :map, default: %{})
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
      add(:rate, :float)
      add(:machine_id, :uuid)
      add(:region, :string)
    end
  end

  defp create_alert_rules_table do
    create table(:alert_rules, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:severity, :string, null: false)
      add(:enabled, :boolean, default: true)
      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all))
      add(:query, :text, null: false)
      add(:condition, :string, null: false)
      add(:threshold, :float, null: false)
      add(:duration_seconds, :integer, default: 60)
      add(:label_matchers, :map, default: %{})
      add(:description, :text)
      add(:summary, :text)
      add(:runbook_url, :string)
      add(:notification_channels, {:array, :string}, default: ["email"])
      add(:evaluation_interval_seconds, :integer, default: 60)
      add(:last_evaluated_at, :utc_datetime_usec)
      add(:last_state, :string)
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
  end

  defp create_alert_instances_table do
    create table(:alert_instances, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:alert_rule_id, references(:alert_rules, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:state, :string, null: false, default: "pending")
      add(:severity, :string, null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:resolved_at, :utc_datetime_usec)
      add(:silenced_until, :utc_datetime_usec)
      add(:labels, :map, default: %{})
      add(:current_value, :float)
      add(:threshold, :float)
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
    # Removed GIN index
  end

  defp create_sla_definitions_table do
    create table(:sla_definitions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all))
      add(:target_value, :float, null: false)
      add(:comparison, :string, null: false)
      add(:window_days, :integer, default: 30)
      add(:error_budget_percent, :float)
      add(:current_value, :float)
      add(:status, :string, default: "meeting")
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
  end

  defp create_sla_violations_table do
    create table(:sla_violations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:sla_id, references(:sla_definitions, type: :uuid, on_delete: :delete_all), null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      add(:duration_seconds, :integer)
      add(:target_value, :float)
      add(:actual_value, :float)
      add(:deviation_percent, :float)
      add(:error_budget_consumed, :float)
      add(:description, :text)
      add(:root_cause, :text)
      add(:remediation, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sla_violations, [:sla_id]))
    create(index(:sla_violations, [:started_at]))
  end

  defp create_dashboards_table do
    create table(:dashboards, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:layout, :map, default: %{})
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
    # Removed GIN index
  end

  defp create_dashboard_panels_table do
    create table(:dashboard_panels, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:dashboard_id, references(:dashboards, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:title, :string, null: false)
      add(:description, :text)
      add(:panel_type, :string, null: false)
      add(:query, :text, null: false)
      add(:visualization_config, :map, default: %{})
      add(:grid_x, :integer, default: 0)
      add(:grid_y, :integer, default: 0)
      add(:grid_width, :integer, default: 12)
      add(:grid_height, :integer, default: 8)
      add(:time_range_from, :string, default: "now-1h")
      add(:time_range_to, :string, default: "now")
      add(:legend_enabled, :boolean, default: true)
      add(:threshold_lines, :map)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:dashboard_panels, [:dashboard_id]))
  end

  defp create_anomaly_models_table do
    create table(:anomaly_models, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:algorithm, :string, null: false)
      add(:parameters, :map, default: %{})
      add(:sensitivity, :float, default: 0.95)
      add(:training_data_days, :integer, default: 14)
      add(:last_trained_at, :utc_datetime_usec)
      add(:model_accuracy, :float)
      add(:enabled, :boolean, default: true)
      add(:model_data, :binary)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:anomaly_models, [:metric_id, :name]))
    create(index(:anomaly_models, [:enabled]))
  end

  defp create_anomalies_table do
    create table(:anomalies, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:model_id, references(:anomaly_models, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:metric_id, references(:metric_definitions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:detected_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      add(:severity, :string, default: "warning")
      add(:anomaly_score, :float, null: false)
      add(:expected_value, :float)
      add(:actual_value, :float)
      add(:deviation_percent, :float)
      add(:labels, :map, default: %{})
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
  end

  defp create_traces_table do
    create table(:traces, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:trace_id, :string, null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:duration_ms, :float)
      add(:service, :string, null: false)
      add(:operation, :string, null: false)
      add(:status, :string)
      add(:error_message, :text)
      add(:span_count, :integer, default: 0)
      add(:tags, :map, default: %{})
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:traces, [:trace_id]))
    create(index(:traces, [:service]))
    create(index(:traces, [:started_at]))
    create(index(:traces, [:status]))
    # Removed GIN index
  end

  defp create_spans_table do
    create table(:spans, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:trace_id, references(:traces, type: :uuid, on_delete: :delete_all), null: false)
      add(:span_id, :string, null: false)
      add(:parent_span_id, :string)
      add(:service, :string, null: false)
      add(:operation, :string, null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:duration_ms, :float, null: false)
      add(:tags, :map, default: %{})
      add(:logs, :map, default: [])
      add(:status, :string)
      add(:error, :boolean, default: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:spans, [:trace_id]))
    create(index(:spans, [:span_id]))
    create(index(:spans, [:service]))
    create(index(:spans, [:started_at]))
    # Removed GIN index
  end
end
