defmodule Orchestrator.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def up do
    create table(:deployments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:service, :string, null: false)
      add(:strategy, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:current_phase, :string)

      add(:from_version, :string)
      add(:to_version, :string, null: false)
      add(:artifact_url, :string)
      add(:artifact_hash, :string)
      add(:artifact_size_bytes, :bigint)

      add(:target_replicas, :integer, null: false)
      add(:min_ready_seconds, :integer, default: 0)
      add(:progress_deadline_seconds, :integer, default: 600)
      add(:revision_history_limit, :integer, default: 10)

      add(:rolling_config, :map, default: %{})
      add(:blue_green_config, :map, default: %{})
      add(:canary_config, :map, default: %{})

      add(:health_check_path, :string, default: "/health")
      add(:health_check_interval_seconds, :integer, default: 10)
      add(:health_check_timeout_seconds, :integer, default: 5)
      add(:health_check_success_threshold, :integer, default: 1)
      add(:health_check_failure_threshold, :integer, default: 3)

      add(:replicas_ready, :integer, default: 0)
      add(:replicas_updated, :integer, default: 0)
      add(:replicas_available, :integer, default: 0)
      add(:replicas_unavailable, :integer, default: 0)

      add(:started_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:duration_ms, :integer)
      add(:paused_at, :utc_datetime)
      add(:pause_duration_ms, :integer)

      add(:rollback_to_version, :string)
      add(:rollback_reason, :text)
      add(:auto_rollback_enabled, :boolean, default: true)
      add(:rollback_on_failure, :boolean, default: true)

      add(:triggered_by, :string)
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

    create table(:deployment_revisions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :delete_all), null: false)
      add(:revision_number, :integer, null: false)
      add(:version, :string, null: false)
      add(:artifact_url, :string, null: false)
      add(:artifact_hash, :string)
      add(:config_snapshot, :map, default: %{})
      add(:replicas, :integer, null: false)
      add(:status, :string, null: false)
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

    create table(:deployment_replicas, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :delete_all), null: false)

      add(:revision_id, references(:deployment_revisions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:replica_name, :string, null: false)
      add(:machine_id, :uuid)
      add(:pod_ip, :string)
      add(:host_ip, :string)
      add(:node_name, :string)

      add(:status, :string, null: false)
      add(:health_status, :string, default: "unknown")
      add(:ready, :boolean, default: false)
      add(:restart_count, :integer, default: 0)

      add(:last_health_check_at, :utc_datetime)
      add(:health_check_success_count, :integer, default: 0)
      add(:health_check_failure_count, :integer, default: 0)
      add(:consecutive_failures, :integer, default: 0)

      add(:created_at_time, :utc_datetime)
      add(:started_at, :utc_datetime)
      add(:ready_at, :utc_datetime)
      add(:terminated_at, :utc_datetime)
      add(:startup_duration_ms, :integer)

      add(:receiving_traffic, :boolean, default: false)
      add(:traffic_weight, :integer, default: 0)
      add(:requests_received, :bigint, default: 0)
      add(:requests_failed, :bigint, default: 0)

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

    create table(:traffic_routes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:split_type, :string, null: false)
      add(:enabled, :boolean, default: true)
      add(:priority, :integer, default: 0)

      add(:old_version_weight, :integer, default: 100)
      add(:new_version_weight, :integer, default: 0)
      add(:sticky_sessions, :boolean, default: false)
      add(:session_affinity_seconds, :integer, default: 3600)

      add(:match_headers, :map, default: %{})
      add(:match_cookies, :map, default: %{})
      add(:match_query_params, :map, default: %{})
      add(:match_ip_ranges, {:array, :string}, default: [])
      add(:match_user_ids, {:array, :string}, default: [])

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

    create table(:deployment_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :delete_all), null: false)
      add(:event_type, :string, null: false)
      add(:event_severity, :string, null: false)
      add(:phase, :string)
      add(:message, :text, null: false)
      add(:reason, :string)
      add(:component, :string)
      add(:replica_name, :string)
      add(:old_value, :string)
      add(:new_value, :string)
      add(:occurred_at, :utc_datetime, null: false)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create table(:deployment_metrics, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :delete_all), null: false)
      add(:metric_name, :string, null: false)
      add(:metric_value, :decimal, precision: 20, scale: 4)
      add(:labels, :map, default: %{})
      add(:timestamp, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create table(:canary_analysis_results, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :delete_all), null: false)
      add(:analysis_run, :integer, null: false)
      add(:started_at, :utc_datetime, null: false)
      add(:completed_at, :utc_datetime)
      add(:duration_ms, :integer)

      add(:baseline_version, :string, null: false)
      add(:canary_version, :string, null: false)
      add(:traffic_percentage, :integer)

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

      add(:passed, :boolean)
      add(:score, :decimal, precision: 5, scale: 2)
      add(:recommendation, :string)
      add(:failure_reasons, {:array, :string}, default: [])

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

    create table(:deployment_hooks, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:deployment_id, references(:deployments, type: :uuid, on_delete: :delete_all), null: false)
      add(:hook_type, :string, null: false)
      add(:hook_name, :string, null: false)
      add(:execution_order, :integer, default: 0)
      add(:command, :text, null: false)
      add(:timeout_seconds, :integer, default: 300)
      add(:retry_count, :integer, default: 0)
      add(:max_retries, :integer, default: 3)
      add(:continue_on_failure, :boolean, default: false)

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

    # Removed triggers, functions, materialize views, hypertables
  end

  def down do
    drop(table(:deployment_hooks))
    drop(table(:canary_analysis_results))
    drop(table(:deployment_metrics))
    drop(table(:deployment_events))
    drop(table(:traffic_routes))
    drop(table(:deployment_replicas))
    drop(table(:deployment_revisions))
    drop(table(:deployments))
  end
end
