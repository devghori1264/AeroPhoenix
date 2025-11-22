defmodule Orchestrator.Repo.Migrations.CreateReconciliationAuditLogs do
  use Ecto.Migration

  def change do
    create table(:reconciliation_audit_logs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :machine_id, :string, null: false
      add :event_type, :string, null: false
      add :severity, :string, null: false
      add :success, :boolean, null: false, default: false

      add :duration_ms, :integer
      add :details, :map, default: %{}

      # Reconciliation-specific fields
      add :reconciliation_level, :string
      add :drift_count, :integer
      add :source_region, :string
      add :target_region, :string

      # Healing-specific fields
      add :healing_strategy, :string
      add :actions_taken, :integer
      add :actions_failed, :integer
      add :rollback_performed, :boolean, default: false

      # Error tracking
      add :error_message, :text
      add :error_details, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:reconciliation_audit_logs, [:machine_id])
    create index(:reconciliation_audit_logs, [:event_type])
    create index(:reconciliation_audit_logs, [:severity])
    create index(:reconciliation_audit_logs, [:success])
    create index(:reconciliation_audit_logs, [:inserted_at])
    create index(:reconciliation_audit_logs, [:machine_id, :inserted_at])
    create index(:reconciliation_audit_logs, [:event_type, :inserted_at])
  end
end
