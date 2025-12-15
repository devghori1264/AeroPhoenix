defmodule Orchestrator.Repo.Migrations.CreateSecurityCompliance do
  use Ecto.Migration

  def up do
    # Security scans table
    create table(:security_scans, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:scan_type, :string, null: false)
      add(:target, :string, null: false)
      add(:target_version, :string)
      add(:scanner, :string, null: false)
      add(:scanner_version, :string)
      add(:status, :string, null: false, default: "queued")
      add(:started_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:duration_ms, :integer)
      add(:findings_count, :integer, default: 0)
      add(:critical_count, :integer, default: 0)
      add(:high_count, :integer, default: 0)
      add(:medium_count, :integer, default: 0)
      add(:low_count, :integer, default: 0)
      add(:info_count, :integer, default: 0)
      add(:scan_config, :map, default: %{})
      add(:error_message, :text)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:security_scans, [:scan_type]))
    create(index(:security_scans, [:target]))
    create(index(:security_scans, [:status]))
    create(index(:security_scans, [:started_at]))
    create(index(:security_scans, [:completed_at]))

    # Vulnerabilities table
    create table(:vulnerabilities, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:scan_id, references(:security_scans, type: :uuid, on_delete: :delete_all), null: false)
      add(:cve_id, :string)
      add(:cwe_id, :string)
      add(:title, :string, null: false)
      add(:description, :text)
      add(:severity, :string, null: false)
      add(:cvss_score, :decimal, precision: 3, scale: 1)
      add(:cvss_vector, :string)
      add(:status, :string, null: false, default: "open")
      add(:package_name, :string)
      add(:package_version, :string)
      add(:fixed_version, :string)
      add(:file_path, :string)
      add(:line_number, :integer)
      add(:code_snippet, :text)
      add(:exploit_available, :boolean, default: false)
      add(:exploit_maturity, :string)
      add(:references, {:array, :string}, default: [])
      add(:assigned_to, :string)
      add(:acknowledged_at, :utc_datetime)
      add(:acknowledged_by, :string)
      add(:resolved_at, :utc_datetime)
      add(:resolved_by, :string)
      add(:resolution_notes, :text)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:vulnerabilities, [:scan_id]))
    create(index(:vulnerabilities, [:cve_id]))
    create(index(:vulnerabilities, [:severity]))
    create(index(:vulnerabilities, [:status]))
    create(index(:vulnerabilities, [:package_name]))

    create(
      unique_index(:vulnerabilities, [:scan_id, :cve_id, :package_name],
        name: :vulnerabilities_unique_finding
      )
    )

    # Security policies table
    create table(:security_policies, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:policy_type, :string, null: false)
      add(:enabled, :boolean, default: true)
      add(:severity_threshold, :string)
      add(:max_cvss_score, :decimal, precision: 3, scale: 1)
      add(:allowed_packages, {:array, :string}, default: [])
      add(:blocked_packages, {:array, :string}, default: [])
      add(:required_scans, {:array, :string}, default: [])
      add(:enforcement_mode, :string, default: "audit")
      add(:policy_rules, :map, default: %{})
      add(:notification_channels, {:array, :string}, default: [])
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:security_policies, [:policy_type]))
    create(index(:security_policies, [:enabled]))
    create(unique_index(:security_policies, [:name]))

    # Compliance frameworks table
    create table(:compliance_frameworks, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:framework, :string, null: false)
      add(:version, :string, null: false)
      add(:enabled, :boolean, default: true)
      add(:description, :text)
      add(:requirements_count, :integer, default: 0)
      add(:compliant_count, :integer, default: 0)
      add(:compliance_percentage, :decimal, precision: 5, scale: 2)
      add(:last_assessed_at, :utc_datetime)
      add(:next_assessment_due, :utc_datetime)
      add(:assessor, :string)
      add(:certification_expiry, :date)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:compliance_frameworks, [:framework]))
    create(index(:compliance_frameworks, [:enabled]))
    create(unique_index(:compliance_frameworks, [:framework, :version]))

    # Compliance requirements table
    create table(:compliance_requirements, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:framework_id, references(:compliance_frameworks, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:requirement_id, :string, null: false)
      add(:title, :string, null: false)
      add(:description, :text)
      add(:category, :string)
      add(:status, :string, null: false, default: "pending_review")
      add(:automated_check, :boolean, default: false)
      add(:check_query, :text)
      add(:evidence_required, :boolean, default: true)
      add(:evidence_description, :text)
      add(:implementation_notes, :text)
      add(:last_checked_at, :utc_datetime)
      add(:last_evidence_at, :utc_datetime)
      add(:assigned_to, :string)
      add(:priority, :string, default: "medium")
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:compliance_requirements, [:framework_id]))
    create(index(:compliance_requirements, [:requirement_id]))
    create(index(:compliance_requirements, [:status]))
    create(index(:compliance_requirements, [:category]))
    create(unique_index(:compliance_requirements, [:framework_id, :requirement_id]))

    # Compliance evidence table
    create table(:compliance_evidence, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :requirement_id,
        references(:compliance_requirements, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:evidence_type, :string, null: false)
      add(:title, :string, null: false)
      add(:description, :text)
      add(:file_path, :string)
      add(:file_url, :string)
      add(:file_hash, :string)
      add(:collected_at, :utc_datetime, null: false)
      add(:collected_by, :string)
      add(:valid_until, :utc_datetime)
      add(:approved, :boolean, default: false)
      add(:approved_at, :utc_datetime)
      add(:approved_by, :string)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:compliance_evidence, [:requirement_id]))
    create(index(:compliance_evidence, [:evidence_type]))
    create(index(:compliance_evidence, [:collected_at]))
    create(index(:compliance_evidence, [:approved]))

    # Encryption keys table (for key rotation tracking)
    create table(:encryption_keys, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:key_name, :string, null: false)
      add(:key_type, :string, null: false)
      add(:algorithm, :string, null: false)
      add(:key_size_bits, :integer)
      add(:key_hash, :string)
      add(:status, :string, null: false, default: "active")
      add(:created_at_epoch, :bigint)
      add(:activated_at, :utc_datetime)
      add(:rotation_due_at, :utc_datetime)
      add(:rotated_at, :utc_datetime)
      add(:revoked_at, :utc_datetime)
      add(:revocation_reason, :text)
      add(:usage_count, :bigint, default: 0)
      add(:last_used_at, :utc_datetime)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:encryption_keys, [:key_name]))
    create(index(:encryption_keys, [:key_type]))
    create(index(:encryption_keys, [:status]))
    create(index(:encryption_keys, [:rotation_due_at]))
    create(unique_index(:encryption_keys, [:key_name, :created_at_epoch]))

    # Audit logs table (security-focused audit trail)
    create table(:security_audit_logs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:event_type, :string, null: false)
      add(:event_category, :string, null: false)
      add(:severity, :string, null: false)
      add(:actor, :string, null: false)
      add(:actor_ip, :string)
      add(:action, :string, null: false)
      add(:resource_type, :string)
      add(:resource_id, :string)
      add(:status, :string, null: false)
      add(:reason, :text)
      add(:request_id, :string)
      add(:session_id, :string)
      add(:user_agent, :string)
      add(:location, :string)
      add(:changes, :map, default: %{})
      add(:metadata, :map, default: %{})
      add(:occurred_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    # Secret scanning results table
    create table(:secret_scan_results, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:scan_id, references(:security_scans, type: :uuid, on_delete: :delete_all), null: false)
      add(:secret_type, :string, null: false)
      add(:file_path, :string, null: false)
      add(:line_number, :integer)
      add(:matched_rule, :string)
      add(:secret_hash, :string)
      add(:entropy_score, :decimal, precision: 5, scale: 2)
      add(:confidence, :string)
      add(:status, :string, default: "open")
      add(:remediated_at, :utc_datetime)
      add(:remediated_by, :string)
      add(:remediation_notes, :text)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:secret_scan_results, [:scan_id]))
    create(index(:secret_scan_results, [:secret_type]))
    create(index(:secret_scan_results, [:status]))
    create(index(:secret_scan_results, [:secret_hash]))

    # Security incidents table
    create table(:security_incidents, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:incident_id, :string, null: false)
      add(:title, :string, null: false)
      add(:description, :text)
      add(:severity, :string, null: false)
      add(:status, :string, null: false, default: "open")
      add(:category, :string, null: false)
      add(:detected_at, :utc_datetime, null: false)
      add(:detected_by, :string)
      add(:detection_method, :string)
      add(:affected_systems, {:array, :string}, default: [])
      add(:affected_users_count, :integer, default: 0)
      add(:data_compromised, :boolean, default: false)
      add(:assigned_to, :string)
      add(:investigation_started_at, :utc_datetime)
      add(:contained_at, :utc_datetime)
      add(:resolved_at, :utc_datetime)
      add(:closed_at, :utc_datetime)
      add(:resolution_summary, :text)
      add(:root_cause, :text)
      add(:lessons_learned, :text)
      add(:mttr_seconds, :integer)
      add(:notification_sent, :boolean, default: false)
      add(:regulatory_reported, :boolean, default: false)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:security_incidents, [:severity]))
    create(index(:security_incidents, [:status]))
    create(index(:security_incidents, [:category]))
    create(index(:security_incidents, [:detected_at]))
    create(unique_index(:security_incidents, [:incident_id]))

    # Removed DB-level automation (Triggers, Functions, Materialized Views, Hypertables)
  end

  def down do
    drop(table(:security_incidents))
    drop(table(:secret_scan_results))
    drop(table(:security_audit_logs))
    drop(table(:encryption_keys))
    drop(table(:compliance_evidence))
    drop(table(:compliance_requirements))
    drop(table(:compliance_frameworks))
    drop(table(:security_policies))
    drop(table(:vulnerabilities))
    drop(table(:security_scans))
  end
end
