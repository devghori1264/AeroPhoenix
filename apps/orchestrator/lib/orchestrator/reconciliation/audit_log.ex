defmodule Orchestrator.Reconciliation.AuditLog do
  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset
  require Logger
  alias Orchestrator.Repo
  @type event_type :: :reconciliation | :healing | :drift_detection | :rollback
  @type severity :: :critical | :major | :minor | :none
  @default_retention_days 90
  schema "reconciliation_audit_logs" do
    field(:machine_id, :string)

    field(:event_type, Ecto.Enum,
      values: [:reconciliation, :healing, :drift_detection, :rollback]
    )

    field(:severity, Ecto.Enum, values: [:critical, :major, :minor, :none])
    field(:success, :boolean)
    field(:duration_ms, :integer)
    field(:details, :map)
    field(:reconciliation_level, Ecto.Enum, values: [:basic, :standard, :deep, :paranoid])
    field(:drift_count, :integer)
    field(:source_region, :string)
    field(:target_region, :string)
    field(:healing_strategy, Ecto.Enum, values: [:auto, :manual, :rollback])
    field(:actions_taken, :integer)
    field(:actions_failed, :integer)
    field(:rollback_performed, :boolean)
    field(:error_message, :string)
    field(:error_details, :map)
    timestamps(type: :utc_datetime_usec)
  end

  def record_reconciliation(machine_id, result, config) do
    attrs = %{
      machine_id: machine_id,
      event_type: :reconciliation,
      severity: result.severity,
      success: result.status == :success,
      duration_ms: result.duration_ms,
      reconciliation_level: config.level,
      drift_count: length(result.inconsistencies),
      source_region: result.source_region,
      target_region: result.target_region,
      details: %{
        inconsistencies: serialize_inconsistencies(result.inconsistencies),
        summary: result.summary,
        recommendations: result.recommendations || []
      }
    }

    attrs =
      if result.status == :failure and result.error do
        Map.merge(attrs, %{
          error_message: to_string(result.error),
          error_details: %{error: inspect(result.error)}
        })
      else
        attrs
      end

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, log} ->
        Logger.debug("Reconciliation event recorded", log_id: log.id, machine_id: machine_id)

        :telemetry.execute(
          [:orchestrator, :audit_log, :recorded],
          %{},
          %{event_type: :reconciliation, machine_id: machine_id}
        )

        {:ok, log}

      {:error, changeset} ->
        Logger.error("Failed to record reconciliation event",
          machine_id: machine_id,
          errors: changeset.errors
        )

        {:error, changeset}
    end
  end

  def record_healing(machine_id, result, config) do
    attrs = %{
      machine_id: machine_id,
      event_type: :healing,
      severity: determine_healing_severity(result),
      success: result.success,
      healing_strategy: config.healing_strategy,
      actions_taken: length(result.actions_taken),
      actions_failed: length(result.actions_failed),
      rollback_performed: result.rollback_performed,
      details: %{
        actions_taken: serialize_actions(result.actions_taken),
        actions_failed: serialize_actions(result.actions_failed),
        dry_run: config.dry_run
      }
    }

    attrs =
      if result.error do
        Map.merge(attrs, %{
          error_message: result.error,
          error_details: %{error: result.error}
        })
      else
        attrs
      end

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, log} ->
        Logger.debug("Healing event recorded", log_id: log.id, machine_id: machine_id)

        :telemetry.execute(
          [:orchestrator, :audit_log, :recorded],
          %{},
          %{event_type: :healing, machine_id: machine_id}
        )

        {:ok, log}

      {:error, changeset} ->
        Logger.error("Failed to record healing event",
          machine_id: machine_id,
          errors: changeset.errors
        )

        {:error, changeset}
    end
  end

  def record_drift_detection(machine_id, analysis_result, source_region, target_region) do
    attrs = %{
      machine_id: machine_id,
      event_type: :drift_detection,
      severity: analysis_result.severity,
      success: true,
      drift_count: length(analysis_result.inconsistencies),
      source_region: source_region,
      target_region: target_region,
      duration_ms: analysis_result.summary.analysis_duration_ms,
      details: %{
        inconsistencies: serialize_inconsistencies(analysis_result.inconsistencies),
        summary: analysis_result.summary,
        recommendations: analysis_result.recommendations
      }
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, log} ->
        Logger.debug("Drift detection event recorded", log_id: log.id, machine_id: machine_id)

        :telemetry.execute(
          [:orchestrator, :audit_log, :recorded],
          %{},
          %{event_type: :drift_detection, machine_id: machine_id}
        )

        {:ok, log}

      {:error, changeset} ->
        Logger.error("Failed to record drift detection event",
          machine_id: machine_id,
          errors: changeset.errors
        )

        {:error, changeset}
    end
  end

  def record_rollback(machine_id, source_region, target_region, reason, success, details \\ %{}) do
    attrs = %{
      machine_id: machine_id,
      event_type: :rollback,
      severity: :critical,
      success: success,
      source_region: source_region,
      target_region: target_region,
      rollback_performed: true,
      details: Map.merge(%{reason: reason}, details)
    }

    attrs =
      if not success do
        Map.merge(attrs, %{
          error_message: "Rollback failed: #{reason}",
          error_details: details
        })
      else
        attrs
      end

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, log} ->
        Logger.debug("Rollback event recorded", log_id: log.id, machine_id: machine_id)

        :telemetry.execute(
          [:orchestrator, :audit_log, :recorded],
          %{},
          %{event_type: :rollback, machine_id: machine_id}
        )

        {:ok, log}

      {:error, changeset} ->
        Logger.error("Failed to record rollback event",
          machine_id: machine_id,
          errors: changeset.errors
        )

        {:error, changeset}
    end
  end

  def query_logs(opts \\ []) do
    query = from(l in __MODULE__)

    query =
      if opts[:machine_id] do
        from(l in query, where: l.machine_id == ^opts[:machine_id])
      else
        query
      end

    query =
      if opts[:event_type] do
        from(l in query, where: l.event_type == ^opts[:event_type])
      else
        query
      end

    query =
      if opts[:severity] do
        from(l in query, where: l.severity == ^opts[:severity])
      else
        query
      end

    query =
      if opts[:success] != nil do
        from(l in query, where: l.success == ^opts[:success])
      else
        query
      end

    query =
      if opts[:since] do
        from(l in query, where: l.inserted_at >= ^opts[:since])
      else
        query
      end

    query =
      if opts[:until] do
        from(l in query, where: l.inserted_at <= ^opts[:until])
      else
        query
      end

    query = from(l in query, order_by: [desc: l.inserted_at])

    query =
      if opts[:limit] do
        from(l in query, limit: ^opts[:limit])
      else
        query
      end

    query =
      if opts[:offset] do
        from(l in query, offset: ^opts[:offset])
      else
        query
      end

    Repo.all(query)
  end

  def get_machine_logs(machine_id, opts \\ []) do
    opts = Keyword.put(opts, :machine_id, machine_id)
    query_logs(opts)
  end

  def get_recent_failures(opts \\ []) do
    defaults = [
      success: false,
      since: DateTime.utc_now() |> DateTime.add(-24 * 60 * 60, :second),
      limit: 100
    ]

    opts = Keyword.merge(defaults, opts)
    query_logs(opts)
  end

  def get_statistics(opts \\ []) do
    since = opts[:since] || DateTime.utc_now() |> DateTime.add(-24 * 60 * 60, :second)
    query = from(l in __MODULE__, where: l.inserted_at >= ^since)
    total = Repo.aggregate(query, :count)

    success_count =
      query
      |> where([l], l.success == true)
      |> Repo.aggregate(:count)

    by_event_type =
      query
      |> group_by([l], l.event_type)
      |> select([l], {l.event_type, count(l.id)})
      |> Repo.all()
      |> Enum.into(%{})

    by_severity =
      query
      |> group_by([l], l.severity)
      |> select([l], {l.severity, count(l.id)})
      |> Repo.all()
      |> Enum.into(%{})

    avg_duration =
      query
      |> where([l], not is_nil(l.duration_ms))
      |> select([l], avg(l.duration_ms))
      |> Repo.one()

    %{
      total_events: total,
      success_count: success_count,
      failure_count: total - success_count,
      success_rate: if(total > 0, do: success_count / total, else: 0.0),
      by_event_type: by_event_type,
      by_severity: by_severity,
      avg_duration_ms: avg_duration || 0.0,
      period_start: since,
      period_end: DateTime.utc_now()
    }
  end

  def cleanup_old_logs(retention_days \\ @default_retention_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 24 * 60 * 60, :second)
    query = from(l in __MODULE__, where: l.inserted_at < ^cutoff)

    case Repo.delete_all(query) do
      {count, _} when count > 0 ->
        Logger.info("Cleaned up old audit logs", deleted_count: count, cutoff: cutoff)
        {:ok, count}

      {0, _} ->
        Logger.debug("No old audit logs to clean up")
        {:ok, 0}
    end
  end

  def export_logs(opts \\ []) do
    logs = query_logs(opts)

    exported =
      Enum.map(logs, fn log ->
        %{
          id: log.id,
          machine_id: log.machine_id,
          event_type: log.event_type,
          severity: log.severity,
          success: log.success,
          duration_ms: log.duration_ms,
          timestamp: log.inserted_at,
          details: log.details,
          reconciliation: %{
            level: log.reconciliation_level,
            drift_count: log.drift_count,
            source_region: log.source_region,
            target_region: log.target_region
          },
          healing: %{
            strategy: log.healing_strategy,
            actions_taken: log.actions_taken,
            actions_failed: log.actions_failed,
            rollback_performed: log.rollback_performed
          },
          error: %{
            message: log.error_message,
            details: log.error_details
          }
        }
      end)

    {:ok, exported}
  end

  defp changeset(log, attrs) do
    log
    |> cast(attrs, [
      :machine_id,
      :event_type,
      :severity,
      :success,
      :duration_ms,
      :details,
      :reconciliation_level,
      :drift_count,
      :source_region,
      :target_region,
      :healing_strategy,
      :actions_taken,
      :actions_failed,
      :rollback_performed,
      :error_message,
      :error_details
    ])
    |> validate_required([:machine_id, :event_type, :success])
    |> validate_inclusion(:event_type, [:reconciliation, :healing, :drift_detection, :rollback])
    |> validate_inclusion(:severity, [:critical, :major, :minor, :none])
    |> validate_number(:drift_count, greater_than_or_equal_to: 0)
    |> validate_number(:actions_taken, greater_than_or_equal_to: 0)
    |> validate_number(:actions_failed, greater_than_or_equal_to: 0)
  end

  defp serialize_inconsistencies(inconsistencies) do
    Enum.map(inconsistencies, fn inc ->
      %{
        field: inc.field,
        source_value: serialize_value(inc.source_value),
        target_value: serialize_value(inc.target_value),
        severity: inc.severity,
        category: inc.category,
        description: inc.description
      }
    end)
  end

  defp serialize_actions(actions) do
    Enum.map(actions, fn action ->
      %{
        action: action.action,
        field: action.field,
        from_value: serialize_value(action.from_value),
        to_value: serialize_value(action.to_value),
        reasoning: action.reasoning,
        risk_level: action.risk_level
      }
    end)
  end

  defp serialize_value(value) when is_binary(value), do: value
  defp serialize_value(value) when is_number(value), do: value
  defp serialize_value(value) when is_boolean(value), do: value
  defp serialize_value(value) when is_nil(value), do: nil
  defp serialize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp serialize_value(value) when is_list(value), do: Enum.map(value, &serialize_value/1)

  defp serialize_value(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end

  defp serialize_value(value), do: inspect(value)

  defp determine_healing_severity(result) do
    cond do
      result.rollback_performed -> :critical
      length(result.actions_failed) > length(result.actions_taken) -> :major
      length(result.actions_failed) > 0 -> :minor
      true -> :none
    end
  end
end
