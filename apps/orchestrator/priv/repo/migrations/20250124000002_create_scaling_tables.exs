defmodule Orchestrator.Repo.Migrations.CreateScalingTables do
  use Ecto.Migration

  def change do
    create table(:scaling_policies, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:service_name, :string, null: false)
      add(:strategy, :string, null: false)
      add(:min_instances, :integer, null: false)
      add(:max_instances, :integer, null: false)
      add(:target_cpu_percent, :integer)
      add(:target_memory_percent, :integer)
      add(:target_request_rate, :integer)
      add(:scale_out_cooldown_seconds, :integer, default: 300)
      add(:scale_in_cooldown_seconds, :integer, default: 600)
      add(:scale_out_increment, :integer, default: 1)
      add(:scale_in_decrement, :integer, default: 1)
      add(:prediction_confidence_threshold, :float, default: 0.8)
      add(:enabled, :boolean, default: true)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:scaling_policies, [:service_name]))
    create(index(:scaling_policies, [:enabled]))
    create(index(:scaling_policies, [:strategy]))

    create(
      constraint(:scaling_policies, :max_greater_than_min,
        check: "max_instances >= min_instances"
      )
    )

    create table(:scaling_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:service_name, :string, null: false)
      add(:event_type, :string, null: false)
      add(:trigger_reason, :string, null: false)
      add(:previous_instance_count, :integer)
      add(:new_instance_count, :integer)
      add(:cpu_utilization, :float)
      add(:memory_utilization, :float)
      add(:request_rate, :float)
      add(:prediction_confidence, :float)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:scaling_events, [:service_name]))
    create(index(:scaling_events, [:event_type]))
    create(index(:scaling_events, [:inserted_at]))

    create table(:metric_samples, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:service_name, :string, null: false)
      add(:metric_name, :string, null: false)
      add(:value, :float, null: false)
      add(:timestamp, :utc_datetime_usec, null: false)
      add(:tags, :map, default: %{})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:metric_samples, [:service_name, :metric_name]))
    create(index(:metric_samples, [:timestamp]))

    create table(:metric_definitions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:type, :string, null: false)
      add(:unit, :string, null: false)
      add(:aggregation, :string, null: false)
      add(:collection_interval_seconds, :integer, default: 60)
      add(:retention_days, :integer, default: 7)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:metric_definitions, [:name]))
    create(index(:metric_definitions, [:type]))
  end
end
