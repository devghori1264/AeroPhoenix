defmodule Orchestrator.Reconciliation.AutoHealer do
  require Logger
  alias Orchestrator.{FlydClient, Manager}
  alias Orchestrator.Reconciliation.AuditLog
  @type healing_strategy :: :auto | :manual | :rollback
  @type drift_severity :: :critical | :major | :minor | :none
  @type inconsistency :: %{
          field: String.t(),
          source_value: any(),
          target_value: any(),
          severity: drift_severity(),
          category: atom(),
          description: String.t()
        }
  @type healing_action :: %{
          action: atom(),
          field: String.t(),
          from_value: any(),
          to_value: any(),
          reasoning: String.t(),
          risk_level: :low | :medium | :high | :critical
        }
  @type healing_result :: %{
          success: boolean(),
          actions_taken: [healing_action()],
          actions_failed: [healing_action()],
          rollback_performed: boolean(),
          error: String.t() | nil
        }
  @max_healing_attempts 3
  @healing_window_minutes 10
  @critical_drift_threshold 0
  @major_drift_threshold 3
  @minor_drift_threshold 10
  @spec heal(String.t(), [inconsistency()], map()) ::
          {:ok, healing_result()} | {:error, term()}
  def heal(machine_id, inconsistencies, config) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Starting healing process",
      machine_id: machine_id,
      strategy: config.healing_strategy,
      drift_count: length(inconsistencies),
      dry_run: config.dry_run
    )

    case check_rate_limit(machine_id) do
      :ok ->
        perform_healing(machine_id, inconsistencies, config, start_time)

      {:error, reason} ->
        Logger.warning("Healing rate limited",
          machine_id: machine_id,
          reason: reason
        )

        {:error, {:rate_limited, reason}}
    end
  end

  defp perform_healing(machine_id, inconsistencies, config, start_time) do
    result =
      case config.healing_strategy do
        :auto ->
          auto_heal(machine_id, inconsistencies, config)

        :manual ->
          manual_heal(machine_id, inconsistencies, config)

        :rollback ->
          rollback_heal(machine_id, inconsistencies, config)

        unknown ->
          Logger.error("Unknown healing strategy", strategy: unknown)
          {:error, {:invalid_strategy, unknown}}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, healing_result} ->
        log_healing_result(machine_id, healing_result, config, duration_ms)

        :telemetry.execute(
          [:orchestrator, :reconciliation, :healing, :completed],
          %{
            duration_ms: duration_ms,
            actions_taken: length(healing_result.actions_taken),
            actions_failed: length(healing_result.actions_failed)
          },
          %{
            machine_id: machine_id,
            strategy: config.healing_strategy,
            success: healing_result.success
          }
        )

        {:ok, healing_result}

      {:error, reason} = error ->
        Logger.error("Healing failed",
          machine_id: machine_id,
          reason: reason,
          duration_ms: duration_ms
        )

        :telemetry.execute(
          [:orchestrator, :reconciliation, :healing, :failed],
          %{duration_ms: duration_ms},
          %{machine_id: machine_id, reason: reason}
        )

        error
    end
  end

  defp auto_heal(machine_id, inconsistencies, config) do
    case verify_healing_safety(inconsistencies, config) do
      :safe ->
        execute_auto_healing(machine_id, inconsistencies, config)

      {:unsafe, reason} ->
        Logger.warning("Auto-healing deemed unsafe",
          machine_id: machine_id,
          reason: reason
        )

        manual_heal(machine_id, inconsistencies, config)
    end
  end

  defp execute_auto_healing(machine_id, inconsistencies, config) do
    actions = plan_healing_actions(inconsistencies, config)

    Logger.info("Executing auto-healing",
      machine_id: machine_id,
      action_count: length(actions),
      dry_run: config.dry_run
    )

    {successful, failed} = execute_actions(machine_id, actions, config)
    success = length(failed) == 0

    rollback_performed =
      if not success and config.rollback_on_failure do
        Logger.warning("Healing partially failed, performing rollback",
          machine_id: machine_id,
          failed_count: length(failed)
        )

        perform_rollback(machine_id, successful, config)
        true
      else
        false
      end

    result = %{
      success: success and not rollback_performed,
      actions_taken: successful,
      actions_failed: failed,
      rollback_performed: rollback_performed,
      error: if(length(failed) > 0, do: "#{length(failed)} actions failed", else: nil)
    }

    {:ok, result}
  end

  defp manual_heal(machine_id, inconsistencies, _config) do
    Logger.info("Manual healing - reporting inconsistencies",
      machine_id: machine_id,
      drift_count: length(inconsistencies)
    )

    actions =
      Enum.map(inconsistencies, fn inc ->
        %{
          action: :report,
          field: inc.field,
          from_value: inc.target_value,
          to_value: inc.source_value,
          reasoning: inc.description,
          risk_level: map_severity_to_risk(inc.severity)
        }
      end)

    result = %{
      success: true,
      actions_taken: actions,
      actions_failed: [],
      rollback_performed: false,
      error: nil
    }

    {:ok, result}
  end

  defp rollback_heal(machine_id, inconsistencies, config) do
    Logger.warning("Rollback healing initiated",
      machine_id: machine_id,
      drift_count: length(inconsistencies)
    )

    case get_source_machine_info(machine_id) do
      {:ok, source_info} ->
        action = %{
          action: :rollback_to_source,
          field: "all",
          from_value: "target_region",
          to_value: "source_region",
          reasoning: "Too much drift detected, reverting to source region state",
          risk_level: :critical
        }

        if config.dry_run do
          Logger.info("DRY RUN: Would rollback machine to source region",
            machine_id: machine_id,
            source_region: source_info.region
          )

          result = %{
            success: true,
            actions_taken: [action],
            actions_failed: [],
            rollback_performed: true,
            error: nil
          }

          {:ok, result}
        else
          case execute_rollback_to_source(machine_id, source_info, config) do
            :ok ->
              result = %{
                success: true,
                actions_taken: [action],
                actions_failed: [],
                rollback_performed: true,
                error: nil
              }

              {:ok, result}

            {:error, reason} ->
              failed_action = %{action | risk_level: :critical}

              result = %{
                success: false,
                actions_taken: [],
                actions_failed: [failed_action],
                rollback_performed: false,
                error: "Rollback failed: #{inspect(reason)}"
              }

              {:ok, result}
          end
        end

      {:error, reason} ->
        {:error, {:rollback_failed, reason}}
    end
  end

  defp verify_healing_safety(inconsistencies, config) do
    critical_count = Enum.count(inconsistencies, &(&1.severity == :critical))
    major_count = Enum.count(inconsistencies, &(&1.severity == :major))
    minor_count = Enum.count(inconsistencies, &(&1.severity == :minor))

    cond do
      critical_count > config.critical_threshold || @critical_drift_threshold ->
        {:unsafe, "Too many critical drifts (#{critical_count})"}

      major_count > config.major_threshold || @major_drift_threshold ->
        {:unsafe, "Too many major drifts (#{major_count})"}

      minor_count > @minor_drift_threshold ->
        {:unsafe, "Too many minor drifts (#{minor_count})"}

      Enum.any?(inconsistencies, &(&1.category == :integrity)) ->
        {:unsafe, "Data integrity issues detected"}

      Enum.any?(inconsistencies, &(&1.category == :identity)) ->
        {:unsafe, "Identity field mismatch - possible corruption"}

      true ->
        :safe
    end
  end

  defp plan_healing_actions(inconsistencies, _config) do
    inconsistencies
    |> Enum.sort_by(&priority_score(&1), :desc)
    |> Enum.map(&plan_action/1)
    |> Enum.reject(&is_nil/1)
  end

  defp priority_score(inconsistency) do
    base_score =
      case inconsistency.severity do
        :critical -> 1000
        :major -> 100
        :minor -> 10
        :none -> 0
      end

    category_bonus =
      case inconsistency.category do
        :integrity -> 500
        :state -> 200
        :resource -> 150
        :configuration -> 100
        :network -> 80
        :storage -> 70
        _ -> 0
      end

    base_score + category_bonus
  end

  defp plan_action(inconsistency) do
    case inconsistency.category do
      :configuration ->
        %{
          action: :update_configuration,
          field: inconsistency.field,
          from_value: inconsistency.target_value,
          to_value: inconsistency.source_value,
          reasoning: "Sync configuration from source to target",
          risk_level: map_severity_to_risk(inconsistency.severity)
        }

      :state ->
        %{
          action: :update_status,
          field: inconsistency.field,
          from_value: inconsistency.target_value,
          to_value: inconsistency.source_value,
          reasoning: "Reconcile machine status with source",
          risk_level: map_severity_to_risk(inconsistency.severity)
        }

      :resource ->
        %{
          action: :update_resources,
          field: inconsistency.field,
          from_value: inconsistency.target_value,
          to_value: inconsistency.source_value,
          reasoning: "Sync resource allocation from source",
          risk_level: :high
        }

      :network ->
        %{
          action: :update_network,
          field: inconsistency.field,
          from_value: inconsistency.target_value,
          to_value: inconsistency.source_value,
          reasoning: "Repair network configuration",
          risk_level: map_severity_to_risk(inconsistency.severity)
        }

      :storage ->
        %{
          action: :resync_storage,
          field: inconsistency.field,
          from_value: inconsistency.target_value,
          to_value: inconsistency.source_value,
          reasoning: "Re-sync storage volumes",
          risk_level: :high
        }

      :integrity ->
        %{
          action: :verify_and_repair,
          field: inconsistency.field,
          from_value: inconsistency.target_value,
          to_value: inconsistency.source_value,
          reasoning: "Critical data integrity issue - verification required",
          risk_level: :critical
        }

      _ ->
        nil
    end
  end

  defp execute_actions(machine_id, actions, config) do
    Enum.reduce(actions, {[], []}, fn action, {successful, failed} ->
      if config.dry_run do
        Logger.info("DRY RUN: Would execute action",
          machine_id: machine_id,
          action: action.action,
          field: action.field
        )

        {[action | successful], failed}
      else
        case execute_single_action(machine_id, action, config) do
          :ok ->
            Logger.info("Healing action succeeded",
              machine_id: machine_id,
              action: action.action,
              field: action.field
            )

            {[action | successful], failed}

          {:error, reason} ->
            Logger.error("Healing action failed",
              machine_id: machine_id,
              action: action.action,
              field: action.field,
              reason: reason
            )

            {successful, [action | failed]}
        end
      end
    end)
  end

  defp execute_single_action(machine_id, action, config) do
    :telemetry.execute(
      [:orchestrator, :reconciliation, :healing, :action, :started],
      %{},
      %{machine_id: machine_id, action: action.action}
    )

    result =
      case action.action do
        :update_configuration ->
          update_machine_configuration(machine_id, action.field, action.to_value, config)

        :update_status ->
          update_machine_status(machine_id, action.to_value, config)

        :update_resources ->
          update_machine_resources(machine_id, action.field, action.to_value, config)

        :update_network ->
          update_machine_network(machine_id, action.field, action.to_value, config)

        :resync_storage ->
          resync_machine_storage(machine_id, action.field, config)

        :verify_and_repair ->
          verify_and_repair_data(machine_id, config)

        _ ->
          {:error, :unknown_action}
      end

    :telemetry.execute(
      [:orchestrator, :reconciliation, :healing, :action, :completed],
      %{},
      %{machine_id: machine_id, action: action.action, success: result == :ok}
    )

    result
  end

  defp update_machine_configuration(machine_id, field, value, _config) do
    case Manager.get_machine(machine_id) do
      {:ok, machine} ->
        region = machine.target_region || machine.region
        FlydClient.update_machine_config(region, machine_id, %{field => value})

      error ->
        error
    end
  end

  defp update_machine_status(machine_id, new_status, _config) do
    case Manager.update_machine_status(machine_id, new_status) do
      {:ok, _machine} -> :ok
      error -> error
    end
  end

  defp update_machine_resources(machine_id, field, value, _config) do
    case Manager.get_machine(machine_id) do
      {:ok, machine} ->
        region = machine.target_region || machine.region
        FlydClient.update_machine_resources(region, machine_id, %{field => value})

      error ->
        error
    end
  end

  defp update_machine_network(machine_id, field, value, _config) do
    case Manager.get_machine(machine_id) do
      {:ok, machine} ->
        region = machine.target_region || machine.region
        FlydClient.update_machine_network(region, machine_id, %{field => value})

      error ->
        error
    end
  end

  defp resync_machine_storage(machine_id, _field, _config) do
    Logger.warning("Storage resync not yet implemented", machine_id: machine_id)
    {:error, :not_implemented}
  end

  defp verify_and_repair_data(machine_id, _config) do
    Logger.warning("Data verification not yet implemented", machine_id: machine_id)
    {:error, :not_implemented}
  end

  defp perform_rollback(machine_id, successful_actions, config) do
    Logger.info("Rolling back healing actions",
      machine_id: machine_id,
      action_count: length(successful_actions)
    )

    Enum.each(Enum.reverse(successful_actions), fn action ->
      rollback_action = %{action | to_value: action.from_value, from_value: action.to_value}

      case execute_single_action(machine_id, rollback_action, config) do
        :ok ->
          Logger.debug("Rollback action succeeded",
            machine_id: machine_id,
            action: action.action
          )

        {:error, reason} ->
          Logger.error("Rollback action failed",
            machine_id: machine_id,
            action: action.action,
            reason: reason
          )
      end
    end)

    :ok
  end

  defp execute_rollback_to_source(machine_id, source_info, _config) do
    case Manager.get_machine(machine_id) do
      {:ok, machine} ->
        target_region = machine.target_region

        if target_region do
          case FlydClient.destroy_machine(target_region, machine_id) do
            :ok ->
              Manager.update_machine(%{
                id: machine_id,
                status: "running",
                region: source_info.region,
                target_region: nil,
                migration_status: "rolled_back"
              })

            error ->
              error
          end
        else
          {:error, :no_target_region}
        end

      error ->
        error
    end
  end

  defp get_source_machine_info(machine_id) do
    case Manager.get_machine(machine_id) do
      {:ok, machine} ->
        {:ok, %{region: machine.region, name: machine.name}}

      error ->
        error
    end
  end

  defp check_rate_limit(machine_id) do
    recent_healings = get_recent_healing_attempts(machine_id)

    if length(recent_healings) >= @max_healing_attempts do
      {:error,
       "Too many healing attempts (#{length(recent_healings)}) in last #{@healing_window_minutes} minutes"}
    else
      record_healing_attempt(machine_id)
      :ok
    end
  end

  defp get_recent_healing_attempts(_machine_id) do
    _cutoff = DateTime.utc_now() |> DateTime.add(-@healing_window_minutes * 60, :second)
    []
  end

  defp record_healing_attempt(_machine_id) do
    :ok
  end

  defp map_severity_to_risk(:critical), do: :critical
  defp map_severity_to_risk(:major), do: :high
  defp map_severity_to_risk(:minor), do: :medium
  defp map_severity_to_risk(:none), do: :low

  defp log_healing_result(machine_id, result, config, duration_ms) do
    Logger.info("Healing completed",
      machine_id: machine_id,
      success: result.success,
      actions_taken: length(result.actions_taken),
      actions_failed: length(result.actions_failed),
      rollback_performed: result.rollback_performed,
      duration_ms: duration_ms,
      dry_run: config.dry_run
    )

    AuditLog.record_healing(machine_id, result, config)
  end
end
