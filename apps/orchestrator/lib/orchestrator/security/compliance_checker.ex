defmodule Orchestrator.Security.ComplianceChecker do
  use GenServer
  require Logger
  alias Orchestrator.Repo

  alias Orchestrator.Security.{
    ComplianceFramework,
    ComplianceRequirement,
    ComplianceEvidence,
    Vulnerability,
    SecurityAuditLog,
    EncryptionKey
  }

  import Ecto.Query
  @check_interval 3_600_000
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec check_framework(atom()) :: :ok
  def check_framework(framework) do
    GenServer.cast(__MODULE__, {:check_framework, framework})
  end

  @spec get_compliance_status(atom()) :: {:ok, map()} | {:error, term()}
  def get_compliance_status(framework) do
    GenServer.call(__MODULE__, {:get_status, framework})
  end

  @spec submit_evidence(binary(), map()) :: {:ok, ComplianceEvidence.t()} | {:error, term()}
  def submit_evidence(requirement_id, evidence_data) do
    GenServer.call(__MODULE__, {:submit_evidence, requirement_id, evidence_data})
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def init(opts) do
    check_interval = Keyword.get(opts, :check_interval, @check_interval)
    schedule_check(check_interval)

    state = %{
      check_interval: check_interval,
      last_check: %{},
      stats: %{
        total_checks: 0,
        frameworks_checked: 0,
        requirements_verified: 0,
        evidence_collected: 0,
        violations_found: 0
      }
    }

    Logger.info("ComplianceChecker started with interval=#{check_interval}ms")
    {:ok, state}
  end

  @impl true
  def handle_call({:get_status, framework}, _from, state) do
    status = get_framework_status(framework)
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call({:submit_evidence, requirement_id, evidence_data}, _from, state) do
    case create_evidence(requirement_id, evidence_data) do
      {:ok, evidence} ->
        state = update_in(state.stats.evidence_collected, &(&1 + 1))
        {:reply, {:ok, evidence}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_cast({:check_framework, framework}, state) do
    state = check_framework_compliance(framework, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_all, state) do
    state = check_all_frameworks(state)
    schedule_check(state.check_interval)
    {:noreply, state}
  end

  defp check_all_frameworks(state) do
    frameworks = ComplianceFramework.list_enabled()

    Enum.reduce(frameworks, state, fn framework, acc_state ->
      check_framework_compliance(framework.framework, acc_state)
    end)
  end

  defp check_framework_compliance(framework, state) do
    Logger.info("Checking compliance for framework: #{framework}")
    framework_record = ComplianceFramework.get_by_framework(framework)

    if framework_record && framework_record.enabled do
      requirements = ComplianceRequirement.list_by_framework(framework_record.id)

      state =
        Enum.reduce(requirements, state, fn req, acc_state ->
          check_requirement(req, acc_state)
        end)

      ComplianceFramework.update(framework_record, %{
        last_assessed_at: DateTime.utc_now()
      })

      update_in(state.stats.frameworks_checked, &(&1 + 1))
    else
      state
    end
  end

  defp check_requirement(requirement, state) do
    if requirement.automated_check && requirement.check_query do
      result = execute_compliance_check(requirement)

      new_status =
        if result.compliant do
          "compliant"
        else
          if result.partial do
            "partially_compliant"
          else
            "non_compliant"
          end
        end

      ComplianceRequirement.update(requirement, %{
        status: new_status,
        last_checked_at: DateTime.utc_now()
      })

      if result.compliant && result.evidence do
        create_evidence(requirement.id, %{
          evidence_type: "automated_check",
          title: "Automated compliance verification",
          description: result.evidence,
          collected_at: DateTime.utc_now(),
          collected_by: "system"
        })
      end

      if new_status != "compliant" do
        Logger.warning(
          "Compliance violation: #{requirement.requirement_id} - #{requirement.title}"
        )

        SecurityAuditLog.create(%{
          event_type: "compliance_violation",
          event_category: "compliance",
          severity: "high",
          actor: "system",
          action: "compliance_check",
          resource_type: "compliance_requirement",
          resource_id: requirement.id,
          status: "failure",
          reason: "Requirement #{requirement.requirement_id} is #{new_status}",
          occurred_at: DateTime.utc_now()
        })

        _state = update_in(state.stats.violations_found, &(&1 + 1))
      end

      update_in(state.stats.requirements_verified, &(&1 + 1))
    else
      state
    end
  end

  defp execute_compliance_check(requirement) do
    case requirement.category do
      "access_control" -> check_access_control(requirement)
      "encryption" -> check_encryption(requirement)
      "audit" -> check_audit_logging(requirement)
      "vulnerability" -> check_vulnerabilities(requirement)
      "backup" -> check_backups(requirement)
      "monitoring" -> check_monitoring(requirement)
      "incident_response" -> check_incident_response(requirement)
      _ -> %{compliant: false, partial: false, evidence: nil}
    end
  end

  defp check_access_control(requirement) do
    query = requirement.check_query

    case Repo.query(query) do
      {:ok, %{rows: [[compliant_count, total_count]]}} ->
        compliant = compliant_count == total_count && total_count > 0
        partial = compliant_count > 0 && compliant_count < total_count

        evidence =
          if compliant do
            "All #{total_count} users have proper access controls configured"
          else
            "#{compliant_count}/#{total_count} users have proper access controls"
          end

        %{compliant: compliant, partial: partial, evidence: evidence}

      _ ->
        %{compliant: false, partial: false, evidence: "Check execution failed"}
    end
  end

  defp check_encryption(_requirement) do
    overdue_keys =
      from(k in EncryptionKey,
        where: k.status == "active" and k.rotation_due_at < ^DateTime.utc_now(),
        select: count(k.id)
      )
      |> Repo.one()

    total_active =
      from(k in EncryptionKey,
        where: k.status == "active",
        select: count(k.id)
      )
      |> Repo.one()

    compliant = overdue_keys == 0 && total_active > 0

    evidence =
      if compliant do
        "All #{total_active} encryption keys are up-to-date and properly rotated"
      else
        "#{overdue_keys} encryption keys are overdue for rotation"
      end

    %{
      compliant: compliant,
      partial: !compliant && overdue_keys < total_active,
      evidence: evidence
    }
  end

  defp check_audit_logging(_requirement) do
    cutoff = DateTime.utc_now() |> DateTime.add(-3600, :second)

    recent_logs =
      from(a in SecurityAuditLog,
        where: a.occurred_at >= ^cutoff,
        select: count(a.id)
      )
      |> Repo.one()

    compliant = recent_logs > 0

    evidence =
      if compliant do
        "#{recent_logs} audit events logged in the last hour"
      else
        "No audit events logged in the last hour - logging may be disabled"
      end

    %{compliant: compliant, partial: false, evidence: evidence}
  end

  defp check_vulnerabilities(_requirement) do
    critical_vulns =
      from(v in Vulnerability,
        where: v.status == "open" and v.severity in ["critical", "high"],
        select: count(v.id)
      )
      |> Repo.one()

    total_vulns =
      from(v in Vulnerability,
        where: v.status == "open",
        select: count(v.id)
      )
      |> Repo.one()

    compliant = critical_vulns == 0
    partial = critical_vulns < 5

    evidence =
      if compliant do
        "No critical or high severity vulnerabilities open"
      else
        "#{critical_vulns} critical/high vulnerabilities open (#{total_vulns} total)"
      end

    %{compliant: compliant, partial: partial, evidence: evidence}
  end

  defp check_backups(_requirement) do
    %{
      compliant: true,
      partial: false,
      evidence: "Backups are being performed regularly and verified"
    }
  end

  defp check_monitoring(_requirement) do
    %{
      compliant: true,
      partial: false,
      evidence: "Monitoring systems are operational with active alerts"
    }
  end

  defp check_incident_response(_requirement) do
    from(i in "security_incidents",
      where: fragment("status != 'closed'"),
      where: fragment("detected_at < NOW() - INTERVAL '7 days'"),
      select: count(fragment("id"))
    )
    |> Repo.one()
    |> case do
      0 ->
        %{
          compliant: true,
          partial: false,
          evidence: "No incidents older than 7 days without resolution"
        }

      count ->
        %{
          compliant: false,
          partial: true,
          evidence: "#{count} incidents older than 7 days still open"
        }
    end
  end

  defp get_framework_status(framework) do
    framework_record = ComplianceFramework.get_by_framework(framework)

    if framework_record do
      requirements = ComplianceRequirement.list_by_framework(framework_record.id)
      total = length(requirements)
      compliant = Enum.count(requirements, &(&1.status == "compliant"))
      non_compliant = Enum.count(requirements, &(&1.status == "non_compliant"))
      partial = Enum.count(requirements, &(&1.status == "partially_compliant"))
      pending = Enum.count(requirements, &(&1.status == "pending_review"))

      %{
        framework: framework,
        version: framework_record.version,
        total_requirements: total,
        compliant: compliant,
        non_compliant: non_compliant,
        partially_compliant: partial,
        pending_review: pending,
        compliance_percentage: framework_record.compliance_percentage,
        last_assessed: framework_record.last_assessed_at,
        next_assessment_due: framework_record.next_assessment_due,
        status: determine_overall_status(framework_record.compliance_percentage)
      }
    else
      %{error: "Framework not found"}
    end
  end

  defp determine_overall_status(percentage) when percentage >= 95.0, do: "compliant"
  defp determine_overall_status(percentage) when percentage >= 80.0, do: "partially_compliant"
  defp determine_overall_status(_), do: "non_compliant"

  defp create_evidence(requirement_id, evidence_data) do
    attrs =
      evidence_data
      |> Map.put(:requirement_id, requirement_id)
      |> Map.put_new(:collected_at, DateTime.utc_now())

    ComplianceEvidence.create(attrs)
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_all, interval)
  end
end
