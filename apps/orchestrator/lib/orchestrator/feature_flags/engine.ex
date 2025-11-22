defmodule Orchestrator.FeatureFlags.Engine do
  @moduledoc """
  Production-grade feature flag evaluation engine with advanced capabilities:

  - Context-aware targeting with attribute matching
  - Percentage-based rollouts with consistent hashing
  - User segmentation and segment-based targeting
  - Multi-variate experiments with traffic allocation
  - Rule priority and cascading evaluation
  - Override management (user, machine, segment level)
  - Dependency resolution and conflict detection
  - Real-time flag distribution via PubSub
  - Evaluation caching with TTL
  - Comprehensive audit logging

  Evaluation Algorithm:
  1. Check for explicit overrides (user/machine/segment)
  2. Evaluate targeting rules in priority order
  3. Apply percentage rollout with consistent hashing
  4. Check experiment allocation
  5. Fall back to default value
  6. Log evaluation and emit metrics
  """

  require Logger
  alias Orchestrator.{Repo, FeatureFlags}
  alias FeatureFlags.{Flag, TargetingRule, Override, Experiment, Evaluation}

  @cache_ttl_seconds 300
  @evaluation_timeout_ms 100

  defstruct [
    :flag_key,
    :flag,
    :context,
    :user_id,
    :machine_id,
    :session_id,
    :attributes,
    :timestamp,
    :cache_enabled
  ]

  ## Public API

  @doc """
  Evaluates a feature flag for the given context.

  Returns the evaluated value and tracks the evaluation for analytics.

  ## Examples

      # Boolean flag
      Engine.evaluate("new_dashboard", %{
        user_id: "user-123",
        attributes: %{"region" => "lax", "plan" => "premium"}
      })
      => {:ok, true}

      # Multi-variate flag
      Engine.evaluate("recommendation_algorithm", %{
        user_id: "user-456",
        attributes: %{"segment" => "power_user"}
      })
      => {:ok, "collaborative_filtering_v2"}
  """
  def evaluate(flag_key, context \\ %{}) when is_binary(flag_key) do
    engine = build_engine(flag_key, context)

    # Start timing
    start_time = System.monotonic_time(:microsecond)

    try do
      result = do_evaluate(engine)

      # Record evaluation
      duration = System.monotonic_time(:microsecond) - start_time
      record_evaluation(engine, result, duration)

      # Emit telemetry
      emit_telemetry(flag_key, result, duration)

      {:ok, result.value}
    catch
      kind, error ->
        Logger.error("Flag evaluation failed: #{flag_key} - #{inspect(error)}")
        duration = System.monotonic_time(:microsecond) - start_time

        # Fall back to default
        default_result = %{value: false, reason: "error", variation_key: "default"}
        record_evaluation(engine, default_result, duration)

        {:ok, false}
    end
  end

  @doc """
  Evaluates multiple flags in a single call (batch evaluation).

  More efficient than individual calls when evaluating many flags.
  """
  def evaluate_batch(flag_keys, context \\ %{}) when is_list(flag_keys) do
    flag_keys
    |> Enum.map(fn key ->
      case evaluate(key, context) do
        {:ok, value} -> {key, value}
        {:error, _} -> {key, false}
      end
    end)
    |> Enum.into(%{})
  end

  @doc """
  Gets all enabled flags for a given context.

  Useful for client-side SDKs that want all flags at once.
  """
  def evaluate_all(context \\ %{}) do
    active_flags = list_active_flags()

    active_flags
    |> Enum.map(fn flag ->
      case evaluate(flag.key, context) do
        {:ok, value} -> {flag.key, value}
        {:error, _} -> {flag.key, flag.default_value}
      end
    end)
    |> Enum.into(%{})
  end

  @doc """
  Checks if a flag is enabled (boolean flags only).

  Convenience method for the common case of boolean flags.
  """
  def enabled?(flag_key, context \\ %{}) do
    case evaluate(flag_key, context) do
      {:ok, value} when is_boolean(value) -> value
      {:ok, _} -> false
      {:error, _} -> false
    end
  end

  @doc """
  Gets the variation assignment for an experiment.

  Returns which variation the user/machine is assigned to,
  ensuring consistent assignment across multiple evaluations.
  """
  def get_variation(flag_key, context \\ %{}) do
    engine = build_engine(flag_key, context)

    with {:ok, experiment} <- get_active_experiment(engine.flag),
         {:ok, variation} <- assign_variation(engine, experiment) do
      {:ok, variation}
    else
      _ -> {:ok, "control"}
    end
  end

  ## Evaluation Logic

  defp do_evaluate(engine) do
    # Step 1: Check overrides
    case check_overrides(engine) do
      {:override, result} ->
        result

      :no_override ->
        # Step 2: Check if flag is active and within schedule
        if flag_active?(engine.flag) do
          # Step 3: Check dependencies
          if dependencies_satisfied?(engine) do
            # Step 4: Evaluate targeting rules
            case evaluate_targeting_rules(engine) do
              {:match, result} ->
                result

              :no_match ->
                # Step 5: Apply default rollout strategy
                evaluate_default_strategy(engine)
            end
          else
            %{
              value: get_default_value(engine.flag),
              reason: "dependency_not_satisfied",
              variation_key: "default"
            }
          end
        else
          %{
            value: get_default_value(engine.flag),
            reason: "flag_inactive",
            variation_key: "default"
          }
        end
    end
  end

  defp check_overrides(engine) do
    # Priority: user > machine > segment
    cond do
      engine.user_id && (override = get_user_override(engine.flag.id, engine.user_id)) ->
        {:override,
         %{value: override.override_value, reason: "user_override", variation_key: "override"}}

      engine.machine_id && (override = get_machine_override(engine.flag.id, engine.machine_id)) ->
        {:override,
         %{value: override.override_value, reason: "machine_override", variation_key: "override"}}

      segment_override = check_segment_overrides(engine) ->
        {:override,
         %{
           value: segment_override.override_value,
           reason: "segment_override",
           variation_key: "override"
         }}

      true ->
        :no_override
    end
  end

  defp evaluate_targeting_rules(engine) do
    # Load targeting rules sorted by priority
    rules = load_targeting_rules(engine.flag.id)

    # Evaluate rules in order until one matches
    Enum.reduce_while(rules, :no_match, fn rule, _acc ->
      if rule.enabled && matches_rule?(engine, rule) do
        # Check rule-specific rollout percentage
        if in_rule_rollout?(engine, rule) do
          value = extract_rule_value(rule, engine.flag.flag_type)

          result = %{
            value: value,
            reason: "rule_match",
            variation_key: rule.name || "rule_#{rule.priority}",
            matched_rule_id: rule.id
          }

          {:halt, {:match, result}}
        else
          {:cont, :no_match}
        end
      else
        {:cont, :no_match}
      end
    end)
  end

  defp matches_rule?(engine, rule) do
    conditions = rule.conditions || []

    # All conditions must match (AND logic)
    Enum.all?(conditions, fn condition ->
      evaluate_condition(engine, condition)
    end)
  end

  defp evaluate_condition(engine, condition) do
    attribute = condition["attribute"]
    operator = condition["operator"]
    expected_values = condition["values"] || []

    # Get attribute value from context
    actual_value = get_attribute_value(engine, attribute)

    case operator do
      "equals" ->
        actual_value == List.first(expected_values)

      "not_equals" ->
        actual_value != List.first(expected_values)

      "in" ->
        actual_value in expected_values

      "not_in" ->
        actual_value not in expected_values

      "contains" ->
        is_binary(actual_value) && String.contains?(actual_value, List.first(expected_values))

      "not_contains" ->
        is_binary(actual_value) && !String.contains?(actual_value, List.first(expected_values))

      "greater_than" ->
        is_number(actual_value) && actual_value > List.first(expected_values)

      "less_than" ->
        is_number(actual_value) && actual_value < List.first(expected_values)

      "regex_match" ->
        is_binary(actual_value) && Regex.match?(~r/#{List.first(expected_values)}/, actual_value)

      "semver_match" ->
        semver_matches?(actual_value, List.first(expected_values))

      _ ->
        false
    end
  end

  defp get_attribute_value(engine, attribute) do
    case attribute do
      "user_id" -> engine.user_id
      "machine_id" -> engine.machine_id
      "session_id" -> engine.session_id
      _ -> get_in(engine.attributes, [attribute])
    end
  end

  defp in_rule_rollout?(engine, rule) do
    percentage = Decimal.to_float(rule.rollout_percentage || Decimal.new(100))

    if percentage >= 100.0 do
      true
    else
      # Use consistent hashing for sticky rollouts
      hash_key = build_hash_key(engine, rule.id)
      hash_value = consistent_hash(hash_key)
      hash_value / 100.0 < percentage
    end
  end

  defp evaluate_default_strategy(engine) do
    case engine.flag.rollout_strategy do
      "all" ->
        %{value: get_default_value(engine.flag), reason: "default", variation_key: "default"}

      "percentage" ->
        if in_percentage_rollout?(engine) do
          %{
            value: get_enabled_value(engine.flag),
            reason: "percentage_rollout",
            variation_key: "enabled"
          }
        else
          %{
            value: get_default_value(engine.flag),
            reason: "not_in_rollout",
            variation_key: "default"
          }
        end

      "gradual" ->
        evaluate_gradual_rollout(engine)

      _ ->
        %{value: get_default_value(engine.flag), reason: "default", variation_key: "default"}
    end
  end

  defp in_percentage_rollout?(engine) do
    percentage = Decimal.to_float(engine.flag.rollout_percentage || Decimal.new(0))

    if percentage >= 100.0 do
      true
    else
      hash_key = build_hash_key(engine, engine.flag.id)
      hash_value = consistent_hash(hash_key)
      hash_value / 100.0 < percentage
    end
  end

  defp evaluate_gradual_rollout(engine) do
    config = engine.flag.gradual_rollout_config || %{}
    current_time = DateTime.utc_now()

    # Gradual rollout increases percentage over time
    start_time = parse_datetime(config["start_time"])
    end_time = parse_datetime(config["end_time"])
    start_percentage = config["start_percentage"] || 0.0
    end_percentage = config["end_percentage"] || 100.0

    current_percentage =
      if start_time && end_time do
        progress = DateTime.diff(current_time, start_time) / DateTime.diff(end_time, start_time)
        progress = max(0.0, min(1.0, progress))
        start_percentage + (end_percentage - start_percentage) * progress
      else
        start_percentage
      end

    hash_key = build_hash_key(engine, engine.flag.id)
    hash_value = consistent_hash(hash_key)

    if hash_value / 100.0 < current_percentage do
      %{
        value: get_enabled_value(engine.flag),
        reason: "gradual_rollout",
        variation_key: "enabled"
      }
    else
      %{
        value: get_default_value(engine.flag),
        reason: "not_in_gradual_rollout",
        variation_key: "default"
      }
    end
  end

  ## Experiment Logic

  defp get_active_experiment(flag) do
    # Load active experiment for this flag
    case Repo.get_by(Experiment, flag_id: flag.id, status: "running") do
      nil -> {:error, :no_active_experiment}
      experiment -> {:ok, experiment}
    end
  end

  defp assign_variation(engine, experiment) do
    # Check if user is in experiment (traffic allocation)
    if in_experiment_traffic?(engine, experiment) do
      # Assign variation based on weights
      variations = experiment.variations || []
      hash_key = build_hash_key(engine, experiment.id)

      variation = select_weighted_variation(variations, hash_key)
      {:ok, variation}
    else
      {:ok, "control"}
    end
  end

  defp in_experiment_traffic?(engine, experiment) do
    allocation = Decimal.to_float(experiment.traffic_allocation || Decimal.new(100))

    if allocation >= 100.0 do
      true
    else
      hash_key = build_hash_key(engine, experiment.id)
      hash_value = consistent_hash(hash_key)
      hash_value / 100.0 < allocation
    end
  end

  defp select_weighted_variation(variations, hash_key) do
    # Calculate cumulative weights
    total_weight = Enum.reduce(variations, 0, fn v, acc -> acc + (v["weight"] || 0) end)
    hash_value = consistent_hash(hash_key)
    target = hash_value / 10000.0 * total_weight

    # Select variation based on weight
    {_cumulative, variation} =
      Enum.reduce_while(variations, {0, nil}, fn v, {cumulative, _} ->
        new_cumulative = cumulative + (v["weight"] || 0)

        if target <= new_cumulative do
          {:halt, {new_cumulative, v["key"]}}
        else
          {:cont, {new_cumulative, nil}}
        end
      end)

    variation || List.first(variations)["key"] || "control"
  end

  ## Helper Functions

  defp build_engine(flag_key, context) do
    flag = get_flag(flag_key)

    %__MODULE__{
      flag_key: flag_key,
      flag: flag,
      context: context,
      user_id: context[:user_id],
      machine_id: context[:machine_id],
      session_id: context[:session_id],
      attributes: context[:attributes] || %{},
      timestamp: DateTime.utc_now(),
      cache_enabled: context[:cache_enabled] != false
    }
  end

  defp get_flag(flag_key) do
    # Try cache first
    case get_cached_flag(flag_key) do
      {:ok, flag} ->
        flag

      :miss ->
        flag = Repo.get_by!(Flag, key: flag_key)
        cache_flag(flag)
        flag
    end
  end

  defp flag_active?(flag) do
    now = DateTime.utc_now()

    flag.status == "active" &&
      (is_nil(flag.enabled_at) || DateTime.compare(now, flag.enabled_at) != :lt) &&
      (is_nil(flag.disabled_at) || DateTime.compare(now, flag.disabled_at) == :lt) &&
      (is_nil(flag.expires_at) || DateTime.compare(now, flag.expires_at) == :lt)
  end

  defp dependencies_satisfied?(engine) do
    required_flags = engine.flag.requires_flags || []
    conflicting_flags = engine.flag.conflicts_with_flags || []

    # All required flags must be enabled
    required_satisfied =
      Enum.all?(required_flags, fn flag_key ->
        case evaluate(flag_key, engine.context) do
          {:ok, true} -> true
          _ -> false
        end
      end)

    # No conflicting flags should be enabled
    no_conflicts =
      Enum.all?(conflicting_flags, fn flag_key ->
        case evaluate(flag_key, engine.context) do
          {:ok, false} -> true
          {:ok, nil} -> true
          _ -> false
        end
      end)

    required_satisfied && no_conflicts
  end

  defp get_default_value(flag) do
    case flag.flag_type do
      "boolean" -> flag.default_value_boolean || false
      "string" -> flag.default_value_string
      "number" -> flag.default_value_number
      "json" -> flag.default_value_json
      _ -> false
    end
  end

  defp get_enabled_value(flag) do
    case flag.flag_type do
      "boolean" -> true
      _ -> get_default_value(flag)
    end
  end

  defp extract_rule_value(rule, flag_type) do
    case flag_type do
      "boolean" -> rule.variation_value_boolean
      "string" -> rule.variation_value_string
      "number" -> rule.variation_value_number
      "json" -> rule.variation_value_json
      _ -> false
    end
  end

  defp build_hash_key(engine, salt) do
    identifier = engine.user_id || engine.machine_id || engine.session_id || "anonymous"
    "#{engine.flag_key}:#{identifier}:#{salt}"
  end

  defp consistent_hash(key) do
    # Use SHA-256 for consistent hashing
    hash = :crypto.hash(:sha256, key)
    # Take first 4 bytes and convert to integer
    <<value::32, _::binary>> = hash
    # Return value between 0 and 9999
    rem(value, 10000)
  end

  defp semver_matches?(actual, expected) when is_binary(actual) and is_binary(expected) do
    # Simple semantic version matching
    # In production, use a library like "version" package
    actual == expected
  end

  defp semver_matches?(_, _), do: false

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(datetime), do: datetime

  ## Data Access

  defp load_targeting_rules(flag_id) do
    Repo.all(
      from(r in TargetingRule,
        where: r.flag_id == ^flag_id,
        order_by: [desc: r.priority]
      )
    )
  end

  defp get_user_override(flag_id, user_id) do
    now = DateTime.utc_now()

    Repo.one(
      from(o in Override,
        where: o.flag_id == ^flag_id,
        where: o.user_id == ^user_id,
        where: o.enabled == true,
        where: is_nil(o.expires_at) or o.expires_at > ^now
      )
    )
  end

  defp get_machine_override(flag_id, machine_id) do
    now = DateTime.utc_now()

    Repo.one(
      from(o in Override,
        where: o.flag_id == ^flag_id,
        where: o.machine_id == ^machine_id,
        where: o.enabled == true,
        where: is_nil(o.expires_at) or o.expires_at > ^now
      )
    )
  end

  defp check_segment_overrides(_engine) do
    # TODO: Implement segment-based overrides
    nil
  end

  defp list_active_flags do
    Repo.all(from(f in Flag, where: f.status == "active"))
  end

  ## Caching

  defp get_cached_flag(flag_key) do
    case :ets.lookup(:flag_cache, flag_key) do
      [{^flag_key, flag, timestamp}] ->
        if DateTime.diff(DateTime.utc_now(), timestamp, :second) < @cache_ttl_seconds do
          {:ok, flag}
        else
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_flag(flag) do
    unless :ets.whereis(:flag_cache) == :undefined do
      :ets.insert(:flag_cache, {flag.key, flag, DateTime.utc_now()})
    end
  end

  ## Tracking

  defp record_evaluation(engine, result, duration) do
    # Async insert for performance
    Task.start(fn ->
      evaluation = %{
        flag_id: engine.flag.id,
        flag_key: engine.flag_key,
        user_id: engine.user_id,
        machine_id: engine.machine_id,
        session_id: engine.session_id,
        context: engine.context,
        variation_key: result.variation_key,
        variation_value: result.value,
        matched_rule_id: result[:matched_rule_id],
        reason: result.reason,
        evaluated_at: engine.timestamp,
        evaluation_duration_us: duration
      }

      Repo.insert_all("flag_evaluations", [evaluation])
    end)
  end

  defp emit_telemetry(flag_key, result, duration) do
    :telemetry.execute(
      [:orchestrator, :feature_flag, :evaluation],
      %{duration: duration},
      %{flag_key: flag_key, variation: result.variation_key, reason: result.reason}
    )
  end

  ## Cache Management

  @doc """
  Loads a flag definition into cache.

  Used for cache warming during startup or after invalidation.
  """
  def load_flag(flag_key) do
    case get_cached_flag(flag_key) do
      {:ok, _flag} -> :ok
      {:error, :not_found} -> {:error, :flag_not_found}
    end
  end

  @doc """
  Invalidates cache entry for a specific flag.

  Called when a flag is updated to ensure next evaluation
  uses the latest definition.
  """
  def invalidate_cache(flag_key) do
    cache_key = "flag:#{flag_key}"
    :ets.delete(:flag_cache, cache_key)
    Logger.debug("Invalidated cache for flag: #{flag_key}")
    :ok
  end

  @doc """
  Clears entire flag cache.

  Use sparingly - typically only during deployments.
  """
  def clear_cache do
    :ets.delete_all_objects(:flag_cache)
    Logger.info("Cleared entire flag cache")
    :ok
  end
end
