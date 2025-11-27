defmodule Orchestrator.Cost.PolicyEngine do
  use GenServer
  require Logger
  alias Orchestrator.{Repo, Machines}
  alias Orchestrator.Cost.RightsizingRecommendation
  import Ecto.Query

  @type state :: %{
          evaluation_interval_ms: integer(),
          dry_run: boolean(),
          last_evaluation_at: DateTime.t() | nil,
          total_evaluations: integer(),
          total_actions_executed: integer(),
          total_actions_skipped: integer(),
          actions_by_type: map(),
          cooldowns: map()
        }
  @default_interval_ms 300_000
  @idle_threshold_hours 24
  @cooldown_period_seconds 3600
  @max_actions_per_cycle 10
  @action_shutdown "shutdown"
  @action_rightsize "rightsize"
  @action_alert "alert"
  @action_tag "tag"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec evaluate_now() :: :ok
  def evaluate_now do
    GenServer.cast(__MODULE__, :evaluate_now)
  end

  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @spec set_dry_run(boolean()) :: :ok
  def set_dry_run(enabled) do
    GenServer.cast(__MODULE__, {:set_dry_run, enabled})
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :evaluation_interval_ms, @default_interval_ms)
    dry_run = Keyword.get(opts, :dry_run, false)

    state = %{
      evaluation_interval_ms: interval,
      dry_run: dry_run,
      last_evaluation_at: nil,
      total_evaluations: 0,
      total_actions_executed: 0,
      total_actions_skipped: 0,
      actions_by_type: %{},
      cooldowns: %{}
    }

    schedule_evaluation(interval)
    Logger.info("PolicyEngine started (dry_run: #{dry_run}, interval: #{interval}ms)")
    {:ok, state}
  end

  @impl true
  def handle_cast(:evaluate_now, state) do
    new_state = evaluate_policies(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:set_dry_run, enabled}, state) do
    Logger.info("PolicyEngine dry_run mode: #{enabled}")
    {:noreply, %{state | dry_run: enabled}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      status: if(state.dry_run, do: "dry_run", else: "active"),
      total_evaluations: state.total_evaluations,
      total_actions_executed: state.total_actions_executed,
      total_actions_skipped: state.total_actions_skipped,
      actions_by_type: state.actions_by_type,
      active_cooldowns: map_size(state.cooldowns),
      last_evaluation_at: state.last_evaluation_at
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:evaluate, state) do
    new_state = evaluate_policies(state)
    schedule_evaluation(state.evaluation_interval_ms)
    {:noreply, new_state}
  end

  defp evaluate_policies(state) do
    Logger.debug("Evaluating cost optimization policies")
    policies = fetch_active_policies()
    state = clean_expired_cooldowns(state)

    {actions, new_state} =
      Enum.reduce(policies, {[], state}, fn policy, {acc_actions, acc_state} ->
        case evaluate_policy(policy, acc_state) do
          {:ok, policy_actions} ->
            {acc_actions ++ policy_actions, acc_state}
        end
      end)

    final_state =
      actions
      |> Enum.take(@max_actions_per_cycle)
      |> Enum.reduce(new_state, fn action, acc_state ->
        execute_action(action, acc_state)
      end)

    %{
      final_state
      | total_evaluations: state.total_evaluations + 1,
        last_evaluation_at: DateTime.utc_now()
    }
  end

  defp fetch_active_policies do
    query = """
    SELECT id, name, policy_type, conditions, actions, enabled
    FROM optimization_policies
    WHERE enabled = true
    ORDER BY priority DESC
    """

    case Repo.query(query) do
      {:ok, result} ->
        Enum.map(result.rows, fn [id, name, type, conditions, actions, enabled] ->
          %{
            id: id,
            name: name,
            policy_type: type,
            conditions: conditions,
            actions: actions,
            enabled: enabled
          }
        end)

      _ ->
        []
    end
  end

  defp evaluate_policy(policy, state) do
    case policy.policy_type do
      "idle_shutdown" ->
        evaluate_idle_shutdown_policy(policy, state)

      "auto_rightsizing" ->
        evaluate_rightsizing_policy(policy, state)

      "budget_enforcement" ->
        evaluate_budget_policy(policy, state)

      "scheduled_action" ->
        evaluate_scheduled_policy(policy, state)

      "tag_based" ->
        evaluate_tag_policy(policy, state)

      unknown ->
        Logger.warning("Unknown policy type: #{unknown}")
        {:ok, []}
    end
  end

  defp evaluate_idle_shutdown_policy(policy, _state) do
    conditions = policy.conditions || %{}
    idle_hours = Map.get(conditions, "idle_hours", @idle_threshold_hours)
    cpu_threshold = Map.get(conditions, "cpu_threshold", 5.0)
    memory_threshold = Map.get(conditions, "memory_threshold", 20.0)

    query = """
    SELECT machine_id, avg_cpu, avg_memory, idle_hours
    FROM detect_idle_resources($1, $2, $3)
    """

    case Repo.query(query, [idle_hours, cpu_threshold, memory_threshold]) do
      {:ok, result} ->
        actions =
          Enum.map(result.rows, fn [machine_id, cpu, memory, hours] ->
            %{
              type: @action_shutdown,
              target: machine_id,
              policy_id: policy.id,
              policy_name: policy.name,
              reason:
                "Idle for #{Float.round(hours, 2)}h (CPU: #{Float.round(cpu, 2)}%, Memory: #{Float.round(memory, 2)}%)",
              metadata: %{
                idle_hours: hours,
                avg_cpu: cpu,
                avg_memory: memory
              }
            }
          end)

        {:ok, actions}

      error ->
        Logger.error("Failed to evaluate idle shutdown policy: #{inspect(error)}")
        {:ok, []}
    end
  end

  defp evaluate_rightsizing_policy(policy, _state) do
    conditions = policy.conditions || %{}
    min_savings = Decimal.new(Map.get(conditions, "min_monthly_savings", "10.0"))
    min_confidence = Map.get(conditions, "min_confidence", 0.7)

    recommendations =
      from(r in RightsizingRecommendation,
        where:
          r.status == :approved and
            r.monthly_savings >= ^min_savings and
            r.confidence_score >= ^min_confidence,
        order_by: [desc: r.monthly_savings],
        limit: 5
      )
      |> Repo.all()

    actions =
      Enum.map(recommendations, fn rec ->
        %{
          type: @action_rightsize,
          target: rec.machine_id,
          policy_id: policy.id,
          policy_name: policy.name,
          reason:
            "Rightsizing approved (savings: $#{Decimal.to_string(rec.monthly_savings)}/mo, confidence: #{rec.confidence_score})",
          metadata: %{
            recommendation_id: rec.id,
            current_cpu: rec.current_cpu,
            current_memory_mb: rec.current_memory_mb,
            recommended_cpu: rec.recommended_cpu,
            recommended_memory_mb: rec.recommended_memory_mb,
            monthly_savings: rec.monthly_savings
          }
        }
      end)

    {:ok, actions}
  end

  defp evaluate_budget_policy(policy, _state) do
    conditions = policy.conditions || %{}
    threshold_percent = Map.get(conditions, "threshold_percent", 95)

    query = """
    SELECT id, name, scope, scope_value, current_month_spend, monthly_limit
    FROM budgets
    WHERE enabled = true
      AND (current_month_spend / monthly_limit * 100) >= $1
    """

    case Repo.query(query, [threshold_percent]) do
      {:ok, result} ->
        actions =
          Enum.map(result.rows, fn [id, name, scope, scope_value, spend, limit] ->
            %{
              type: @action_alert,
              target: "budget-#{id}",
              policy_id: policy.id,
              policy_name: policy.name,
              reason: "Budget '#{name}' exceeded #{threshold_percent}% (#{spend}/#{limit})",
              metadata: %{
                budget_id: id,
                budget_name: name,
                scope: scope,
                scope_value: scope_value,
                current_spend: spend,
                limit: limit,
                percent_used: spend / limit * 100
              }
            }
          end)

        {:ok, actions}

      error ->
        Logger.error("Failed to evaluate budget policy: #{inspect(error)}")
        {:ok, []}
    end
  end

  defp evaluate_scheduled_policy(policy, _state) do
    conditions = policy.conditions || %{}
    schedule = Map.get(conditions, "schedule", %{})

    if matches_schedule?(schedule) do
      actions = Map.get(policy.actions, "actions", [])

      {:ok,
       Enum.map(actions, fn action ->
         %{
           type: action["type"],
           target: action["target"],
           policy_id: policy.id,
           policy_name: policy.name,
           reason: "Scheduled action executed",
           metadata: action
         }
       end)}
    else
      {:ok, []}
    end
  end

  defp evaluate_tag_policy(policy, _state) do
    conditions = policy.conditions || %{}
    required_tags = Map.get(conditions, "tags", %{})

    query = "SELECT id, tags FROM machines WHERE status = 'started'"

    case Repo.query(query) do
      {:ok, result} ->
        actions =
          result.rows
          |> Enum.filter(fn [_id, tags] ->
            tags_map = tags || %{}
            Enum.any?(required_tags, fn {k, v} -> Map.get(tags_map, k) != v end)
          end)
          |> Enum.map(fn [id, _tags] ->
            %{
              type: @action_tag,
              target: id,
              policy_id: policy.id,
              policy_name: policy.name,
              reason: "Missing required tags: #{inspect(required_tags)}",
              metadata: %{tags: required_tags}
            }
          end)

        {:ok, actions}

      error ->
        Logger.error("Failed to evaluate tag policy: #{inspect(error)}")
        {:ok, []}
    end
  end

  defp execute_action(action, state) do
    if in_cooldown?(action, state) do
      Logger.debug("Action skipped due to cooldown: #{action.target}")

      %{
        state
        | total_actions_skipped: state.total_actions_skipped + 1
      }
    else
      if state.dry_run do
        Logger.info(
          "[DRY-RUN] Would execute: #{action.type} on #{action.target} - #{action.reason}"
        )

        %{
          state
          | total_actions_skipped: state.total_actions_skipped + 1
        }
      else
        case perform_action(action) do
          :ok ->
            Logger.info("Action executed: #{action.type} on #{action.target} - #{action.reason}")
            log_action(action)

            state
            |> increment_action_executed(action.type)
            |> add_cooldown(action)

          {:error, reason} ->
            Logger.error("Action failed: #{action.type} on #{action.target} - #{inspect(reason)}")
            %{state | total_actions_skipped: state.total_actions_skipped + 1}
        end
      end
    end
  end

  defp perform_action(%{type: @action_shutdown, target: machine_id} = action) do
    case Machines.Machine.stop(machine_id) do
      {:ok, _machine} ->
        :ok

      error ->
        error
    end
  rescue
    e ->
      Logger.error("Shutdown action failed for #{action.target}: #{Exception.message(e)}")
      {:error, :shutdown_failed}
  end

  defp perform_action(%{type: @action_rightsize, target: machine_id, metadata: metadata} = action) do
    new_config = %{
      cpu: metadata.recommended_cpu,
      memory_mb: metadata.recommended_memory_mb
    }

    case Machines.Machine.update_config(machine_id, new_config) do
      {:ok, _machine} ->
        if metadata[:recommendation_id] do
          RightsizingRecommendation.mark_implemented(metadata.recommendation_id)
        end

        :ok

      error ->
        error
    end
  rescue
    e ->
      Logger.error("Rightsizing action failed for #{action.target}: #{Exception.message(e)}")
      {:error, :rightsizing_failed}
  end

  defp perform_action(%{type: @action_alert} = action) do
    Logger.warning("POLICY ALERT: #{action.reason}")
    :ok
  end

  defp perform_action(%{type: @action_tag, target: machine_id, metadata: metadata} = action) do
    new_tags = Map.get(metadata, :tags, [])

    case Machines.Machine.update_tags(machine_id, new_tags) do
      {:ok, _machine} -> :ok
      error -> error
    end
  rescue
    e ->
      Logger.error("Tag action failed for #{action.target}: #{Exception.message(e)}")
      {:error, :tag_failed}
  end

  defp perform_action(%{type: unknown_type}) do
    Logger.error("Unknown action type: #{unknown_type}")
    {:error, :unknown_action_type}
  end

  defp log_action(action) do
    query = """
    INSERT INTO policy_execution_logs
      (policy_id, action_type, target, reason, metadata, executed_at)
    VALUES ($1, $2, $3, $4, $5, $6)
    """

    Repo.query(query, [
      action.policy_id,
      action.type,
      action.target,
      action.reason,
      Jason.encode!(action.metadata),
      DateTime.utc_now()
    ])
  rescue
    e ->
      Logger.error("Failed to log action: #{Exception.message(e)}")
      :ok
  end

  defp in_cooldown?(action, state) do
    cooldown_key = "#{action.type}:#{action.target}"
    expires_at = Map.get(state.cooldowns, cooldown_key)

    case expires_at do
      nil -> false
      timestamp -> DateTime.compare(DateTime.utc_now(), timestamp) == :lt
    end
  end

  defp add_cooldown(state, action) do
    cooldown_key = "#{action.type}:#{action.target}"
    expires_at = DateTime.utc_now() |> DateTime.add(@cooldown_period_seconds, :second)
    cooldowns = Map.put(state.cooldowns, cooldown_key, expires_at)
    %{state | cooldowns: cooldowns}
  end

  defp clean_expired_cooldowns(state) do
    now = DateTime.utc_now()

    cooldowns =
      state.cooldowns
      |> Enum.filter(fn {_key, expires_at} ->
        DateTime.compare(now, expires_at) == :lt
      end)
      |> Enum.into(%{})

    %{state | cooldowns: cooldowns}
  end

  defp increment_action_executed(state, action_type) do
    actions_by_type = Map.update(state.actions_by_type, action_type, 1, &(&1 + 1))

    %{
      state
      | total_actions_executed: state.total_actions_executed + 1,
        actions_by_type: actions_by_type
    }
  end

  defp matches_schedule?(schedule) do
    now = DateTime.utc_now()

    day_matches =
      case Map.get(schedule, "days_of_week") do
        nil -> true
        days -> Enum.member?(days, Date.day_of_week(DateTime.to_date(now)))
      end

    hour_matches =
      case Map.get(schedule, "hours") do
        nil ->
          true

        %{"start" => start_hour, "end" => end_hour} ->
          current_hour = now.hour
          current_hour >= start_hour and current_hour <= end_hour
      end

    day_matches and hour_matches
  end

  defp schedule_evaluation(interval_ms) do
    Process.send_after(self(), :evaluate, interval_ms)
  end
end
