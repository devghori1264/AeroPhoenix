defmodule Orchestrator.Repo.Migrations.CreateSecurityCompliance do
  use Ecto.Migration

  def up do
    # Custom types for security and compliance

    execute("""
    CREATE TYPE vulnerability_severity AS ENUM (
      'critical',
      'high',
      'medium',
      'low',
      'info'
    )
    """)

    execute("""
    CREATE TYPE vulnerability_status AS ENUM (
      'open',
      'acknowledged',
      'in_progress',
      'resolved',
      'wont_fix',
      'false_positive'
    )
    """)

    execute("""
    CREATE TYPE scan_status AS ENUM (
      'queued',
      'scanning',
      'completed',
      'failed',
      'cancelled'
    )
    """)

    execute("""
    CREATE TYPE compliance_framework AS ENUM (
      'soc2',
      'hipaa',
      'pci_dss',
      'gdpr',
      'iso27001',
      'nist',
      'fedramp'
    )
    """)

    execute("""
    CREATE TYPE compliance_status AS ENUM (
      'compliant',
      'non_compliant',
      'partially_compliant',
      'not_applicable',
      'pending_review'
    )
    """)

    execute("""
    CREATE TYPE encryption_algorithm AS ENUM (
      'aes_256_gcm',
      'aes_128_gcm',
      'chacha20_poly1305',
      'rsa_2048',
      'rsa_4096',
      'ecdsa_p256',
      'ed25519'
    )
    """)

    # Security scans table
    create table(:security_scans, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      # vulnerability, dependency, secret, configuration, compliance
      add(:scan_type, :string, null: false)
      # machine_id, service_name, image_name, repository
      add(:target, :string, null: false)
      add(:target_version, :string)
      # trivy, clair, grype, semgrep, bandit
      add(:scanner, :string, null: false)
      add(:scanner_version, :string)
      add(:status, :scan_status, null: false, default: "queued")
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
      # CVE-2023-12345
      add(:cve_id, :string)
      # CWE-79
      add(:cwe_id, :string)
      add(:title, :string, null: false)
      add(:description, :text)
      add(:severity, :vulnerability_severity, null: false)
      add(:cvss_score, :decimal, precision: 3, scale: 1)
      add(:cvss_vector, :string)
      add(:status, :vulnerability_status, null: false, default: "open")
      add(:package_name, :string)
      add(:package_version, :string)
      add(:fixed_version, :string)
      add(:file_path, :string)
      add(:line_number, :integer)
      add(:code_snippet, :text)
      add(:exploit_available, :boolean, default: false)
      # unproven, poc, functional, high
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
      # vulnerability, access_control, encryption, network, audit
      add(:policy_type, :string, null: false)
      add(:enabled, :boolean, default: true)
      # Block deployments if vulnerabilities >= threshold
      add(:severity_threshold, :vulnerability_severity)
      add(:max_cvss_score, :decimal, precision: 3, scale: 1)
      add(:allowed_packages, {:array, :string}, default: [])
      add(:blocked_packages, {:array, :string}, default: [])
      add(:required_scans, {:array, :string}, default: [])
      # audit, enforce
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
      add(:framework, :compliance_framework, null: false)
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

      # SOC2-CC6.1, HIPAA-164.312(a)(1)
      add(:requirement_id, :string, null: false)
      add(:title, :string, null: false)
      add(:description, :text)
      # access_control, encryption, audit, incident_response
      add(:category, :string)
      add(:status, :compliance_status, null: false, default: "pending_review")
      add(:automated_check, :boolean, default: false)
      # SQL or code to verify compliance
      add(:check_query, :text)
      add(:evidence_required, :boolean, default: true)
      add(:evidence_description, :text)
      add(:implementation_notes, :text)
      add(:last_checked_at, :utc_datetime)
      add(:last_evidence_at, :utc_datetime)
      add(:assigned_to, :string)
      # critical, high, medium, low
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

      # document, screenshot, log, scan_result, configuration
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
      # data, transport, signing, backup
      add(:key_type, :string, null: false)
      add(:algorithm, :encryption_algorithm, null: false)
      add(:key_size_bits, :integer)
      # Hash of public key for verification
      add(:key_hash, :string)
      # active, rotating, rotated, revoked
      add(:status, :string, null: false, default: "active")
      # For precise rotation tracking
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
      # authentication, authorization, access, modification, deletion
      add(:event_type, :string, null: false)
      # security, compliance, encryption, vulnerability
      add(:event_category, :string, null: false)
      # critical, high, medium, low, info
      add(:severity, :string, null: false)
      # user_id, service_account, api_key
      add(:actor, :string, null: false)
      add(:actor_ip, :string)
      add(:action, :string, null: false)
      add(:resource_type, :string)
      add(:resource_id, :string)
      # success, failure, denied
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

    # Hypertable for time-series audit logs
    execute("""
    SELECT create_hypertable(
      'security_audit_logs',
      'occurred_at',
      chunk_time_interval => INTERVAL '7 days'
    )
    """)

    create(index(:security_audit_logs, [:event_type]))
    create(index(:security_audit_logs, [:event_category]))
    create(index(:security_audit_logs, [:actor]))
    create(index(:security_audit_logs, [:resource_type, :resource_id]))
    create(index(:security_audit_logs, [:status]))
    create(index(:security_audit_logs, [:occurred_at]))

    # Compression policy - compress after 30 days
    execute("""
    SELECT add_compression_policy(
      'security_audit_logs',
      compress_after => INTERVAL '30 days'
    )
    """)

    # Retention policy - keep for 2 years
    execute("""
    SELECT add_retention_policy(
      'security_audit_logs',
      drop_after => INTERVAL '730 days'
    )
    """)

    # Secret scanning results table
    create table(:secret_scan_results, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:scan_id, references(:security_scans, type: :uuid, on_delete: :delete_all), null: false)
      # api_key, password, token, certificate, private_key
      add(:secret_type, :string, null: false)
      add(:file_path, :string, null: false)
      add(:line_number, :integer)
      add(:matched_rule, :string)
      # Hash for deduplication
      add(:secret_hash, :string)
      add(:entropy_score, :decimal, precision: 5, scale: 2)
      # high, medium, low
      add(:confidence, :string)
      # open, verified, false_positive, remediated
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
      # INC-2024-001
      add(:incident_id, :string, null: false)
      add(:title, :string, null: false)
      add(:description, :text)
      add(:severity, :vulnerability_severity, null: false)
      # open, investigating, contained, resolved, closed
      add(:status, :string, null: false, default: "open")
      # data_breach, unauthorized_access, malware, dos, insider_threat
      add(:category, :string, null: false)
      add(:detected_at, :utc_datetime, null: false)
      add(:detected_by, :string)
      # automated, manual, external_report
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
      # Mean Time To Resolve
      add(:mttr_seconds, :integer)
      add(:notification_sent, :boolean, default: false)
      add(:regulatory_reported, :boolean, default: false)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:security_incidents, [:incident_id]))
    create(index(:security_incidents, [:severity]))
    create(index(:security_incidents, [:status]))
    create(index(:security_incidents, [:category]))
    create(index(:security_incidents, [:detected_at]))
    create(unique_index(:security_incidents, [:incident_id]))

    # Functions for auto-updating compliance percentages
    execute("""
    CREATE OR REPLACE FUNCTION update_framework_compliance()
    RETURNS TRIGGER AS $$
    BEGIN
      UPDATE compliance_frameworks
      SET
        compliant_count = (
          SELECT COUNT(*)
          FROM compliance_requirements
          WHERE framework_id = NEW.framework_id
            AND status = 'compliant'
        ),
        requirements_count = (
          SELECT COUNT(*)
          FROM compliance_requirements
          WHERE framework_id = NEW.framework_id
        ),
        compliance_percentage = (
          SELECT
            CASE
              WHEN COUNT(*) > 0 THEN
                (COUNT(*) FILTER (WHERE status = 'compliant')::decimal / COUNT(*) * 100)
              ELSE 0
            END
          FROM compliance_requirements
          WHERE framework_id = NEW.framework_id
        )
      WHERE id = NEW.framework_id;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER trigger_update_framework_compliance
    AFTER INSERT OR UPDATE OF status ON compliance_requirements
    FOR EACH ROW
    EXECUTE FUNCTION update_framework_compliance();
    """)

    # Function for auto-updating scan finding counts
    execute("""
    CREATE OR REPLACE FUNCTION update_scan_finding_counts()
    RETURNS TRIGGER AS $$
    BEGIN
      UPDATE security_scans
      SET
        findings_count = (
          SELECT COUNT(*)
          FROM vulnerabilities
          WHERE scan_id = NEW.scan_id
        ),
        critical_count = (
          SELECT COUNT(*)
          FROM vulnerabilities
          WHERE scan_id = NEW.scan_id AND severity = 'critical'
        ),
        high_count = (
          SELECT COUNT(*)
          FROM vulnerabilities
          WHERE scan_id = NEW.scan_id AND severity = 'high'
        ),
        medium_count = (
          SELECT COUNT(*)
          FROM vulnerabilities
          WHERE scan_id = NEW.scan_id AND severity = 'medium'
        ),
        low_count = (
          SELECT COUNT(*)
          FROM vulnerabilities
          WHERE scan_id = NEW.scan_id AND severity = 'low'
        ),
        info_count = (
          SELECT COUNT(*)
          FROM vulnerabilities
          WHERE scan_id = NEW.scan_id AND severity = 'info'
        )
      WHERE id = NEW.scan_id;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER trigger_update_scan_finding_counts
    AFTER INSERT OR UPDATE OF severity ON vulnerabilities
    FOR EACH ROW
    EXECUTE FUNCTION update_scan_finding_counts();
    """)

    # Materialized view for security posture dashboard
    execute("""
    CREATE MATERIALIZED VIEW security_posture_summary AS
    SELECT
      (SELECT COUNT(*) FROM security_scans WHERE status = 'completed') as total_scans,
      (SELECT COUNT(*) FROM vulnerabilities WHERE status = 'open') as open_vulnerabilities,
      (SELECT COUNT(*) FROM vulnerabilities WHERE status = 'open' AND severity = 'critical') as critical_vulnerabilities,
      (SELECT COUNT(*) FROM vulnerabilities WHERE status = 'open' AND severity = 'high') as high_vulnerabilities,
      (SELECT COUNT(*) FROM security_policies WHERE enabled = true) as active_policies,
      (SELECT AVG(compliance_percentage) FROM compliance_frameworks WHERE enabled = true) as avg_compliance,
      (SELECT COUNT(*) FROM encryption_keys WHERE status = 'active') as active_keys,
      (SELECT COUNT(*) FROM encryption_keys WHERE rotation_due_at < NOW()) as keys_needing_rotation,
      (SELECT COUNT(*) FROM security_incidents WHERE status != 'closed') as open_incidents,
      NOW() as last_updated
    """)

    create(unique_index(:security_posture_summary, [:last_updated]))

    # Materialized view for compliance dashboard
    execute("""
    CREATE MATERIALIZED VIEW compliance_dashboard AS
    SELECT
      cf.framework,
      cf.version,
      cf.compliance_percentage,
      cf.requirements_count,
      cf.compliant_count,
      COUNT(DISTINCT cr.id) FILTER (WHERE cr.status = 'compliant') as requirements_compliant,
      COUNT(DISTINCT cr.id) FILTER (WHERE cr.status = 'non_compliant') as requirements_non_compliant,
      COUNT(DISTINCT cr.id) FILTER (WHERE cr.status = 'partially_compliant') as requirements_partial,
      COUNT(DISTINCT ce.id) as evidence_count,
      MAX(ce.collected_at) as latest_evidence_date,
      cf.last_assessed_at,
      cf.next_assessment_due
    FROM compliance_frameworks cf
    LEFT JOIN compliance_requirements cr ON cr.framework_id = cf.id
    LEFT JOIN compliance_evidence ce ON ce.requirement_id = cr.id
    WHERE cf.enabled = true
    GROUP BY cf.id, cf.framework, cf.version, cf.compliance_percentage,
             cf.requirements_count, cf.compliant_count,
             cf.last_assessed_at, cf.next_assessment_due
    """)

    create(unique_index(:compliance_dashboard, [:framework, :version]))
  end

  def down do
    execute("DROP MATERIALIZED VIEW IF EXISTS compliance_dashboard")
    execute("DROP MATERIALIZED VIEW IF EXISTS security_posture_summary")

    execute("DROP TRIGGER IF EXISTS trigger_update_scan_finding_counts ON vulnerabilities")
    execute("DROP FUNCTION IF EXISTS update_scan_finding_counts()")

    execute(
      "DROP TRIGGER IF EXISTS trigger_update_framework_compliance ON compliance_requirements"
    )

    execute("DROP FUNCTION IF EXISTS update_framework_compliance()")

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

    execute("DROP TYPE IF EXISTS encryption_algorithm")
    execute("DROP TYPE IF EXISTS compliance_status")
    execute("DROP TYPE IF EXISTS compliance_framework")
    execute("DROP TYPE IF EXISTS scan_status")
    execute("DROP TYPE IF EXISTS vulnerability_status")
    execute("DROP TYPE IF EXISTS vulnerability_severity")
  end
end
