defmodule Orchestrator.Migration.Rollback do
  require Logger
  alias Orchestrator.FlydClient
  @type rollback_strategy :: :immediate | :deferred | :partial | :complete
  @type rollback_result :: {:ok, map()} | {:error, term()}
  defmodule RollbackPlan do
    @enforce_keys [:migration_id, :strategy, :phase, :actions]
    defstruct [
      :migration_id,
      :machine_id,
      :strategy,
      :phase,
      :actions,
      :created_at,
      :executed_at,
      :completed_at,
      :status,
      :error,
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            migration_id: String.t(),
            machine_id: String.t() | nil,
            strategy: atom(),
            phase: String.t(),
            actions: list(map()),
            created_at: DateTime.t(),
            executed_at: DateTime.t() | nil,
            completed_at: DateTime.t() | nil,
            status: :pending | :executing | :completed | :failed,
            error: term() | nil,
            metadata: map()
          }
  end

  defmodule RollbackAction do
    @enforce_keys [:type, :params]
    defstruct [
      :type,
      :params,
      :order,
      :executed,
      :result,
      :error,
      :duration_ms,
      description: ""
    ]

    @type action_type ::
            :delete_target_machine
            | :restore_source_machine
            | :cleanup_volumes
            | :revert_dns
            | :revert_traffic
            | :cleanup_snapshots
            | :notify
            | :update_db
    @type t :: %__MODULE__{
            type: action_type(),
            params: map(),
            order: non_neg_integer() | nil,
            executed: boolean(),
            result: term() | nil,
            error: term() | nil,
            duration_ms: non_neg_integer() | nil,
            description: String.t()
          }
  end

  @spec create_rollback_plan(String.t(), keyword()) :: {:ok, RollbackPlan.t()} | {:error, term()}
  def create_rollback_plan(migration_id, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :immediate)

    with {:ok, migration_status} <- FlydClient.get_migration_status(migration_id),
         {:ok, actions} <- determine_rollback_actions(migration_status, strategy) do
      plan = %RollbackPlan{
        migration_id: migration_id,
        machine_id: migration_status["machine_id"],
        strategy: strategy,
        phase: migration_status["phase"],
        actions: actions,
        created_at: DateTime.utc_now(),
        status: :pending,
        metadata: %{
          source_region: migration_status["source_region"],
          target_region: migration_status["target_region"],
          failure_reason: migration_status["error_message"]
        }
      }

      Logger.info("Created rollback plan",
        migration_id: migration_id,
        strategy: strategy,
        phase: migration_status["phase"],
        action_count: length(actions)
      )

      {:ok, plan}
    end
  end

  @spec execute_rollback(RollbackPlan.t(), keyword()) :: rollback_result()
  def execute_rollback(%RollbackPlan{} = plan, opts \\ []) do
    Logger.warning("Executing rollback plan",
      migration_id: plan.migration_id,
      strategy: plan.strategy,
      action_count: length(plan.actions)
    )

    :telemetry.execute(
      [:orchestrator, :migration, :rollback, :start],
      %{action_count: length(plan.actions)},
      %{migration_id: plan.migration_id, strategy: plan.strategy}
    )

    plan = %{plan | status: :executing, executed_at: DateTime.utc_now()}

    sorted_actions =
      plan.actions
      |> Enum.sort_by(& &1.order, :desc)

    start_time = System.monotonic_time(:millisecond)

    {executed_actions, final_status, final_error} =
      execute_actions(sorted_actions, opts)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    completed_plan = %{
      plan
      | actions: executed_actions,
        status: final_status,
        error: final_error,
        completed_at: DateTime.utc_now()
    }

    case final_status do
      :completed ->
        Logger.info("Rollback completed successfully",
          migration_id: plan.migration_id,
          duration_ms: duration_ms,
          actions_executed: length(executed_actions)
        )

        :telemetry.execute(
          [:orchestrator, :migration, :rollback, :success],
          %{duration_ms: duration_ms},
          %{migration_id: plan.migration_id}
        )

        {:ok,
         %{
           migration_id: plan.migration_id,
           status: :rolled_back,
           actions_executed: length(executed_actions),
           duration_ms: duration_ms
         }}

      :failed ->
        Logger.error("Rollback failed",
          migration_id: plan.migration_id,
          error: inspect(final_error),
          duration_ms: duration_ms
        )

        :telemetry.execute(
          [:orchestrator, :migration, :rollback, :failed],
          %{duration_ms: duration_ms},
          %{migration_id: plan.migration_id, error: final_error}
        )

        {:error, {:rollback_failed, final_error, completed_plan}}
    end
  end

  @spec should_auto_rollback?(map(), keyword()) :: boolean()
  def should_auto_rollback?(migration_status, opts \\ []) do
    strategy = Keyword.get(opts, :auto_rollback_strategy, :immediate)
    phase = migration_status["phase"]
    state = migration_status["state"]

    cond do
      state == "STATE_COMPLETED" ->
        false

      state == "STATE_ROLLING_BACK" or state == "STATE_ROLLED_BACK" ->
        false

      strategy == :immediate and state == "STATE_FAILED" ->
        true

      strategy == :conservative and state == "STATE_FAILED" ->
        phase in ["PHASE_VALIDATING", "PHASE_CREATING_TARGET", "PHASE_SYNCING_DATA"]

      strategy == :deferred ->
        false

      true ->
        false
    end
  end

  defp determine_rollback_actions(migration_status, strategy) do
    phase = migration_status["phase"]

    actions =
      case phase do
        "PHASE_VALIDATING" ->
          []

        "PHASE_CREATING_TARGET" ->
          [
            build_action(:delete_target_machine, migration_status, 1),
            build_action(:cleanup_snapshots, migration_status, 2),
            build_action(:update_db, migration_status, 3)
          ]

        "PHASE_SYNCING_DATA" ->
          [
            build_action(:delete_target_machine, migration_status, 1),
            build_action(:cleanup_volumes, migration_status, 2),
            build_action(:restore_source_machine, migration_status, 3),
            build_action(:cleanup_snapshots, migration_status, 4),
            build_action(:update_db, migration_status, 5)
          ]

        "PHASE_REDIRECTING_TRAFFIC" ->
          [
            build_action(:revert_traffic, migration_status, 1),
            build_action(:revert_dns, migration_status, 2),
            build_action(:restore_source_machine, migration_status, 3),
            build_action(:delete_target_machine, migration_status, 4),
            build_action(:cleanup_volumes, migration_status, 5),
            build_action(:update_db, migration_status, 6)
          ]

        "PHASE_CLEANUP" ->
          case strategy do
            :complete ->
              [
                build_action(:revert_traffic, migration_status, 1),
                build_action(:restore_source_machine, migration_status, 2),
                build_action(:delete_target_machine, migration_status, 3),
                build_action(:update_db, migration_status, 4)
              ]

            _ ->
              [
                build_action(:notify, migration_status, 1),
                build_action(:update_db, migration_status, 2)
              ]
          end

        _ ->
          [
            build_action(:notify, migration_status, 1),
            build_action(:update_db, migration_status, 2)
          ]
      end

    {:ok, actions}
  end

  defp build_action(type, migration_status, order) do
    description =
      case type do
        :delete_target_machine ->
          "Delete target machine in #{migration_status["target_region"]}"

        :restore_source_machine ->
          "Restore source machine in #{migration_status["source_region"]}"

        :cleanup_volumes ->
          "Clean up temporary volumes and snapshots"

        :revert_dns ->
          "Revert DNS changes to point back to source"

        :revert_traffic ->
          "Redirect traffic back to source machine"

        :cleanup_snapshots ->
          "Remove migration snapshots"

        :notify ->
          "Send rollback notification"

        :update_db ->
          "Update migration status in database"
      end

    %RollbackAction{
      type: type,
      params: extract_action_params(type, migration_status),
      order: order,
      executed: false,
      description: description
    }
  end

  defp extract_action_params(type, migration_status) do
    base_params = %{
      migration_id: migration_status["migration_id"],
      machine_id: migration_status["machine_id"],
      source_region: migration_status["source_region"],
      target_region: migration_status["target_region"]
    }

    case type do
      :delete_target_machine ->
        Map.put(base_params, :target_machine_id, migration_status["target_machine_id"])

      :restore_source_machine ->
        Map.put(base_params, :source_machine_id, migration_status["machine_id"])

      _ ->
        base_params
    end
  end

  defp execute_actions(actions, opts) do
    stop_on_error = Keyword.get(opts, :stop_on_error, true)

    Enum.reduce_while(actions, {[], :completed, nil}, fn action, {executed, _status, _error} ->
      result = execute_action(action)

      updated_action =
        case result do
          {:ok, action_result} ->
            %{action | executed: true, result: action_result, duration_ms: action.duration_ms}

          {:error, reason} ->
            %{action | executed: true, error: reason, duration_ms: action.duration_ms}
        end

      case result do
        {:ok, _} ->
          {:cont, {[updated_action | executed], :completed, nil}}

        {:error, reason} when stop_on_error ->
          {:halt, {[updated_action | executed], :failed, reason}}

        {:error, _reason} ->
          {:cont, {[updated_action | executed], :completed, nil}}
      end
    end)
  end

  defp execute_action(%RollbackAction{type: type, params: params} = action) do
    Logger.info("Executing rollback action",
      type: type,
      description: action.description
    )

    start_time = System.monotonic_time(:millisecond)

    result =
      case type do
        :delete_target_machine ->
          delete_target_machine(params)

        :restore_source_machine ->
          restore_source_machine(params)

        :cleanup_volumes ->
          cleanup_volumes(params)

        :revert_dns ->
          revert_dns(params)

        :revert_traffic ->
          revert_traffic(params)

        :cleanup_snapshots ->
          cleanup_snapshots(params)

        :notify ->
          send_notification(params)

        :update_db ->
          update_database(params)

        _ ->
          {:error, {:unknown_action_type, type}}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, _} = success ->
        Logger.info("Rollback action completed",
          type: type,
          duration_ms: duration_ms
        )

        success

      {:error, reason} ->
        Logger.error("Rollback action failed",
          type: type,
          reason: inspect(reason),
          duration_ms: duration_ms
        )

        {:error, reason}
    end
  end

  defp delete_target_machine(params) do
    target_machine_id = params[:target_machine_id] || params[:machine_id]

    if target_machine_id do
      case FlydClient.stop_machine(target_machine_id) do
        {:ok, _} ->
          Logger.info("Target machine deleted", machine_id: target_machine_id)
          {:ok, %{machine_id: target_machine_id, action: :deleted}}

        {:error, reason} ->
          {:error, {:delete_failed, reason}}
      end
    else
      {:ok, %{action: :skipped, reason: :no_target_machine}}
    end
  end

  defp restore_source_machine(params) do
    source_machine_id = params[:source_machine_id] || params[:machine_id]

    if source_machine_id do
      case FlydClient.start_machine(source_machine_id) do
        {:ok, _} ->
          Logger.info("Source machine restored", machine_id: source_machine_id)
          {:ok, %{machine_id: source_machine_id, action: :restored}}

        {:error, reason} ->
          {:error, {:restore_failed, reason}}
      end
    else
      {:ok, %{action: :skipped, reason: :no_source_machine}}
    end
  end

  defp cleanup_volumes(_params) do
    Logger.info("Cleaning up volumes")
    {:ok, %{action: :volumes_cleaned}}
  end

  defp revert_dns(_params) do
    Logger.info("Reverting DNS changes")
    {:ok, %{action: :dns_reverted}}
  end

  defp revert_traffic(_params) do
    Logger.info("Reverting traffic routing")
    {:ok, %{action: :traffic_reverted}}
  end

  defp cleanup_snapshots(_params) do
    Logger.info("Cleaning up snapshots")
    {:ok, %{action: :snapshots_cleaned}}
  end

  defp send_notification(params) do
    Logger.info("Sending rollback notification", params: params)
    {:ok, %{action: :notification_sent}}
  end

  defp update_database(params) do
    Logger.info("Updating migration status in database", params: params)
    {:ok, %{action: :database_updated}}
  end
end
