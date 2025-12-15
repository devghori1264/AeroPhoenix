defmodule Orchestrator.Repo.Migrations.CreateFeatureFlagSystem do
  use Ecto.Migration

  def up do
    create table(:feature_flags, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:key, :string, null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:status, :string, null: false, default: "inactive")
      add(:flag_type, :string, null: false, default: "boolean")
      add(:version, :integer, null: false, default: 1)
      add(:previous_version_id, references(:feature_flags, type: :uuid, on_delete: :nilify_all))
      add(:default_value_boolean, :boolean, default: false)
      add(:default_value_string, :string)
      add(:default_value_number, :decimal)
      add(:default_value_json, :map)
      add(:rollout_strategy, :string, null: false, default: "all")
      add(:rollout_percentage, :decimal, default: 0.0)
      add(:gradual_rollout_config, :map)
      add(:owner, :string)
      add(:team, :string)
      add(:tags, {:array, :string}, default: [])
      add(:metadata, :map, default: %{})
      add(:enabled_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec)
      add(:requires_flags, {:array, :string}, default: [])
      add(:conflicts_with_flags, {:array, :string}, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:feature_flags, [:key]))
    create(index(:feature_flags, [:status]))
    create(index(:feature_flags, [:flag_type]))
    create(index(:feature_flags, [:rollout_strategy]))
    create(index(:feature_flags, [:owner]))
    create(index(:feature_flags, [:team]))
    create(index(:feature_flags, [:enabled_at]))
    create(index(:feature_flags, [:expires_at]))

    # Removed CHECK constraint for SQLite simplicity or added via raw sql if strictly needed,
    # but strictly optional for 'up' to assume valid data.

    create table(:flag_targeting_rules, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:flag_id, references(:feature_flags, type: :uuid, on_delete: :delete_all), null: false)
      add(:priority, :integer, null: false, default: 0)
      add(:enabled, :boolean, null: false, default: true)
      add(:name, :string)
      add(:description, :text)
      add(:conditions, :map, null: false, default: [])
      add(:variation_value_boolean, :boolean)
      add(:variation_value_string, :string)
      add(:variation_value_number, :decimal)
      add(:variation_value_json, :map)
      add(:rollout_percentage, :decimal, default: 100.0)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:flag_targeting_rules, [:flag_id]))
    create(index(:flag_targeting_rules, [:priority]))
    create(index(:flag_targeting_rules, [:enabled]))
    create(index(:flag_targeting_rules, [:flag_id, :priority]))

    create table(:user_segments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:key, :string, null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:conditions, :map, null: false, default: [])
      add(:owner, :string)
      add(:tags, {:array, :string}, default: [])
      add(:estimated_size, :integer)
      add(:last_evaluated_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:user_segments, [:key]))
    create(index(:user_segments, [:owner]))

    create table(:experiments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:flag_id, references(:feature_flags, type: :uuid, on_delete: :delete_all), null: false)
      add(:key, :string, null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:hypothesis, :text)
      add(:status, :string, null: false, default: "draft")
      add(:traffic_allocation, :decimal, null: false, default: 100.0)
      add(:variations, :map, null: false)
      add(:primary_metric, :string)
      add(:secondary_metrics, {:array, :string}, default: [])
      add(:minimum_sample_size, :integer, default: 1000)
      add(:confidence_level, :decimal, default: 95.0)
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:winning_variation, :string)
      add(:winner_selected_at, :utc_datetime_usec)
      add(:max_duration_days, :integer, default: 30)
      add(:early_stopping_enabled, :boolean, default: true)
      add(:owner, :string)
      add(:team, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:experiments, [:key]))
    create(index(:experiments, [:flag_id]))
    create(index(:experiments, [:status]))
    create(index(:experiments, [:started_at]))
    create(index(:experiments, [:ended_at]))

    create table(:experiment_results, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:experiment_id, references(:experiments, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:variation_key, :string, null: false)
      add(:metric_name, :string, null: false)
      add(:sample_size, :bigint, default: 0)
      add(:conversion_count, :bigint, default: 0)
      add(:conversion_rate, :decimal)
      add(:sum_of_values, :decimal, default: 0.0)
      add(:mean, :decimal)
      add(:variance, :decimal)
      add(:std_dev, :decimal)
      add(:confidence_lower_bound, :decimal)
      add(:confidence_upper_bound, :decimal)
      add(:relative_improvement, :decimal)
      add(:p_value, :decimal)
      add(:is_significant, :boolean, default: false)
      add(:aggregation_period, :string)
      add(:period_start, :utc_datetime_usec)
      add(:period_end, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:experiment_results, [:experiment_id, :variation_key]))
    create(index(:experiment_results, [:metric_name]))
    create(index(:experiment_results, [:aggregation_period]))
    create(index(:experiment_results, [:period_start, :period_end]))

    create(
      unique_index(
        :experiment_results,
        [:experiment_id, :variation_key, :metric_name, :aggregation_period, :period_start],
        name: :experiment_results_unique_idx
      )
    )

    create table(:flag_evaluations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:flag_id, references(:feature_flags, type: :uuid, on_delete: :delete_all), null: false)
      add(:flag_key, :string, null: false)
      add(:user_id, :string)
      add(:machine_id, :string)
      add(:session_id, :string)
      add(:context, :map, default: %{})
      add(:variation_key, :string)
      add(:variation_value, :map)
      add(:matched_rule_id, :uuid)
      add(:reason, :string)
      add(:experiment_id, :uuid)
      add(:in_experiment, :boolean, default: false)
      add(:evaluated_at, :utc_datetime_usec, null: false)
      add(:evaluation_duration_us, :integer)
    end

    create(index(:flag_evaluations, [:evaluated_at]))
    create(index(:flag_evaluations, [:flag_id]))
    create(index(:flag_evaluations, [:flag_key]))
    create(index(:flag_evaluations, [:user_id]))
    create(index(:flag_evaluations, [:machine_id]))
    create(index(:flag_evaluations, [:experiment_id]))
    create(index(:flag_evaluations, [:in_experiment]))

    create table(:metric_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:experiment_id, references(:experiments, type: :uuid, on_delete: :delete_all))
      add(:flag_id, references(:feature_flags, type: :uuid, on_delete: :delete_all))
      add(:metric_name, :string, null: false)
      add(:event_type, :string, null: false)
      add(:user_id, :string)
      add(:machine_id, :string)
      add(:session_id, :string)
      add(:variation_key, :string)
      add(:value, :decimal)
      add(:properties, :map, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:source, :string)
    end

    create(index(:metric_events, [:experiment_id, :metric_name]))
    create(index(:metric_events, [:flag_id, :metric_name]))
    create(index(:metric_events, [:user_id]))
    create(index(:metric_events, [:occurred_at]))
    create(index(:metric_events, [:variation_key]))

    create table(:flag_audit_logs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:flag_id, references(:feature_flags, type: :uuid, on_delete: :delete_all), null: false)
      add(:flag_key, :string, null: false)
      add(:action, :string, null: false)
      add(:changes, :map)
      add(:actor, :string, null: false)
      add(:actor_type, :string)
      add(:ip_address, :string)
      add(:reason, :text)
      add(:metadata, :map, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)
    end

    create(index(:flag_audit_logs, [:flag_id]))
    create(index(:flag_audit_logs, [:flag_key]))
    create(index(:flag_audit_logs, [:action]))
    create(index(:flag_audit_logs, [:actor]))
    create(index(:flag_audit_logs, [:occurred_at]))

    create table(:flag_overrides, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:flag_id, references(:feature_flags, type: :uuid, on_delete: :delete_all), null: false)
      add(:flag_key, :string, null: false)
      add(:user_id, :string)
      add(:machine_id, :string)
      add(:segment_id, :uuid)
      add(:override_value, :map, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:expires_at, :utc_datetime_usec)
      add(:created_by, :string)
      add(:reason, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:flag_overrides, [:flag_id]))
    create(index(:flag_overrides, [:user_id]))
    create(index(:flag_overrides, [:machine_id]))
    create(index(:flag_overrides, [:segment_id]))
    create(index(:flag_overrides, [:enabled]))
    create(index(:flag_overrides, [:expires_at]))

    # Removed materialized view flag_statistics needed for Postgres
  end

  def down do
    drop(table(:flag_overrides))
    drop(table(:flag_audit_logs))
    drop(table(:metric_events))
    drop(table(:flag_evaluations))
    drop(table(:experiment_results))
    drop(table(:experiments))
    drop(table(:user_segments))
    drop(table(:flag_targeting_rules))
    drop(table(:feature_flags))
  end
end
