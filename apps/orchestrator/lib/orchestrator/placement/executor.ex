defmodule Orchestrator.Placement.Executor do
  use GenServer
  require Logger
  alias Orchestrator.{Repo, Machine, FlydClient}
  alias Orchestrator.Placement.{CostOptimizer, LatencyOptimizer}
  alias Orchestrator.Events.Writer, as: EventWriter
  import Ecto.Query
  @type execution_mode :: :dry_run | :progressive | :atomic | :staged
  @type execution_result :: %{
          success: boolean(),
          executed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          rolled_back_count: non_neg_integer(),
          actions: list(map()),
          errors: list(map()),
          duration_ms: non_neg_integer()
        }
  defstruct [
    :execution_id,
    :mode,
    :dry_run,
    :max_concurrent,
    :timeout_ms,
    :create_checkpoints,
    :auto_rollback,
    :rate_limit_per_minute,
    :state_snapshots,
    :executed_actions,
    :failed_actions,
    :start_time
  ]

  @default_timeout_ms 300_000
  @default_max_concurrent 5
  @default_rate_limit 20
  @checkpoint_retention_hours 72
  @spec apply_cost_optimization(list(map()), keyword()) ::
          {:ok, execution_result()} | {:error, any()}
  def apply_cost_optimization(recommendations, opts \\ []) do
    Logger.info("Applying cost optimization recommendations",
      count: length(recommendations),
      mode: opts[:mode] || :dry_run
    )

    execution = build_execution_context(:cost_optimization, opts)

    with {:ok, validated} <- validate_cost_recommendations(recommendations),
         {:ok, plan} <- create_execution_plan(validated, :cost),
         {:ok, result} <- execute_plan(execution, plan) do
      log_execution_result(:cost_optimization, result)
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.error("Cost optimization execution failed", reason: inspect(reason))
        error
    end
  end

  @spec apply_latency_optimization(list(map()), keyword()) ::
          {:ok, execution_result()} | {:error, any()}
  def apply_latency_optimization(placements, opts \\ []) do
    Logger.info("Applying latency optimization placements",
      count: length(placements),
      mode: opts[:mode] || :dry_run
    )

    execution = build_execution_context(:latency_optimization, opts)

    with {:ok, validated} <- validate_latency_placements(placements),
         {:ok, plan} <- create_execution_plan(validated, :latency),
         {:ok, result} <- execute_plan(execution, plan) do
      log_execution_result(:latency_optimization, result)
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.error("Latency optimization execution failed", reason: inspect(reason))
        error
    end
  end

  @spec execute_placement(map(), keyword()) :: {:ok, map()} | {:error, any()}
  def execute_placement(recommendation, opts \\ []) do
    validate? = Keyword.get(opts, :validate, true)
    create_checkpoint? = Keyword.get(opts, :create_checkpoint, true)
    force? = Keyword.get(opts, :force, false)

    with :ok <- maybe_validate_placement(recommendation, validate?, force?),
         {:ok, checkpoint} <- maybe_create_checkpoint(recommendation, create_checkpoint?),
         {:ok, result} <- do_execute_placement(recommendation) do
      audit_placement_execution(recommendation, result, checkpoint)
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.error("Placement execution failed",
          recommendation: inspect(recommendation),
          reason: inspect(reason)
        )

        error
    end
  end

  @spec rollback_execution(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def rollback_execution(execution_id, opts \\ []) do
    Logger.warn("Rolling back execution", execution_id: execution_id)

    with {:ok, checkpoints} <- load_execution_checkpoints(execution_id),
         {:ok, result} <- perform_rollback(checkpoints, opts) do
      Logger.info("Rollback completed",
        execution_id: execution_id,
        rolled_back: result.rolled_back_count
      )

      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.error("Rollback failed",
          execution_id: execution_id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp validate_cost_recommendations(recommendations) do
    Logger.debug("Validating cost recommendations", count: length(recommendations))

    errors =
      Enum.reduce(recommendations, [], fn rec, acc ->
        case validate_cost_recommendation(rec) do
          :ok -> acc
          {:error, reason} -> [{rec, reason} | acc]
        end
      end)

    if Enum.empty?(errors) do
      {:ok, recommendations}
    else
      {:error, {:validation_failed, errors}}
    end
  end

  defp validate_cost_recommendation(rec) do
    with :ok <- validate_required_fields(rec, [:type, :machine_id]),
         :ok <- validate_machine_exists(rec.machine_id),
         :ok <- validate_recommendation_type(rec.type),
         :ok <- validate_cost_specific_fields(rec) do
      :ok
    end
  end

  defp validate_cost_specific_fields(%{type: :consolidate} = rec) do
    with :ok <- validate_required_fields(rec, [:target_host, :machines_to_move]),
         :ok <- validate_target_capacity(rec.target_host, rec.machines_to_move) do
      :ok
    end
  end

  defp validate_cost_specific_fields(%{type: :rightsize} = rec) do
    with :ok <- validate_required_fields(rec, [:current_specs, :target_specs]),
         :ok <- validate_specs_different(rec.current_specs, rec.target_specs),
         :ok <- validate_specs_valid(rec.target_specs) do
      :ok
    end
  end

  defp validate_cost_specific_fields(%{type: :decommission} = rec) do
    with :ok <- validate_required_fields(rec, [:host_id]),
         :ok <- validate_host_empty(rec.host_id) do
      :ok
    end
  end

  defp validate_cost_specific_fields(_), do: :ok

  defp validate_latency_placements(placements) do
    Logger.debug("Validating latency placements", count: length(placements))

    errors =
      Enum.reduce(placements, [], fn placement, acc ->
        case validate_latency_placement(placement) do
          :ok -> acc
          {:error, reason} -> [{placement, reason} | acc]
        end
      end)

    if Enum.empty?(errors) do
      {:ok, placements}
    else
      {:error, {:validation_failed, errors}}
    end
  end

  defp validate_latency_placement(placement) do
    with :ok <- validate_required_fields(placement, [:machine_id, :target_region]),
         :ok <- validate_machine_exists(placement.machine_id),
         :ok <- validate_region_exists(placement.target_region),
         :ok <- validate_not_same_region(placement.machine_id, placement.target_region),
         :ok <- validate_region_capacity(placement.target_region) do
      :ok
    end
  end

  defp validate_required_fields(map, required_fields) do
    missing = Enum.filter(required_fields, &(!Map.has_key?(map, &1)))

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_fields, missing}}
    end
  end

  defp validate_machine_exists(machine_id) do
    case Repo.get(Machine, machine_id) do
      nil ->
        {:error, {:machine_not_found, machine_id}}

      machine ->
        if machine.status in ["running", "stopped"] do
          :ok
        else
          {:error, {:invalid_machine_state, machine.status}}
        end
    end
  end

  defp validate_recommendation_type(type)
       when type in [:consolidate, :rightsize, :decommission, :migrate],
       do: :ok

  defp validate_recommendation_type(type), do: {:error, {:invalid_type, type}}

  defp validate_target_capacity(target_host, machines) do
    available_slots = get_host_available_capacity(target_host)
    required_slots = length(machines)

    if available_slots >= required_slots do
      :ok
    else
      {:error, {:insufficient_capacity, %{available: available_slots, required: required_slots}}}
    end
  end

  defp validate_specs_different(current, target) do
    if current != target do
      :ok
    else
      {:error, :specs_unchanged}
    end
  end

  defp validate_specs_valid(specs) do
    cond do
      specs[:cpu] && specs[:cpu] > 0 && specs[:cpu] <= 64 -> :ok
      specs[:memory_mb] && specs[:memory_mb] > 0 && specs[:memory_mb] <= 262_144 -> :ok
      true -> {:error, :invalid_specs}
    end
  end

  defp validate_host_empty(host_id) do
    machine_count =
      Repo.aggregate(
        from(m in Machine, where: m.host_id == ^host_id and m.status != "terminated"),
        :count
      )

    if machine_count == 0 do
      :ok
    else
      {:error, {:host_not_empty, machine_count}}
    end
  end

  defp validate_region_exists(region) do
    valid_regions = ["us-east-1", "us-west-2", "eu-west-1", "ap-south-1"]

    if region in valid_regions do
      :ok
    else
      {:error, {:invalid_region, region}}
    end
  end

  defp validate_not_same_region(machine_id, target_region) do
    machine = Repo.get!(Machine, machine_id)

    if machine.region != target_region do
      :ok
    else
      {:error, :same_region}
    end
  end

  defp validate_region_capacity(region) do
    current_count =
      Repo.aggregate(
        from(m in Machine, where: m.region == ^region and m.status == "running"),
        :count
      )

    max_capacity = 100

    if current_count < max_capacity do
      :ok
    else
      {:error, {:region_at_capacity, region}}
    end
  end

  defp maybe_validate_placement(recommendation, true = _validate?, false = _force?) do
    validate_latency_placement(recommendation)
  end

  defp maybe_validate_placement(_recommendation, false = _validate?, _force?), do: :ok
  defp maybe_validate_placement(_recommendation, _validate?, true = _force?), do: :ok

  defp create_execution_plan(recommendations, optimization_type) do
    Logger.debug("Creating execution plan",
      type: optimization_type,
      count: length(recommendations)
    )

    ordered = order_recommendations(recommendations, optimization_type)
    batches = create_execution_batches(ordered)

    plan = %{
      optimization_type: optimization_type,
      total_actions: length(recommendations),
      batches: batches,
      estimated_duration_ms: estimate_duration(batches),
      rollback_points: identify_rollback_points(batches)
    }

    {:ok, plan}
  end

  defp order_recommendations(recommendations, :cost) do
    Enum.sort_by(recommendations, fn rec ->
      type_priority =
        case rec.type do
          :rightsize -> 1
          :consolidate -> 2
          :migrate -> 3
          :decommission -> 4
          _ -> 5
        end

      savings = Map.get(rec, :monthly_savings, Decimal.new(0))
      {type_priority, Decimal.to_float(savings) * -1}
    end)
  end

  defp order_recommendations(recommendations, :latency) do
    Enum.sort_by(recommendations, fn rec ->
      latency_improvement = Map.get(rec, :latency_improvement_ms, 0)
      -latency_improvement
    end)
  end

  defp create_execution_batches(ordered_recommendations) do
    Enum.chunk_every(ordered_recommendations, @default_max_concurrent)
  end

  defp estimate_duration(batches) do
    avg_per_action = 60_000

    Enum.reduce(batches, 0, fn batch, acc ->
      batch_duration = length(batch) * avg_per_action / @default_max_concurrent
      acc + batch_duration
    end)
  end

  defp identify_rollback_points(batches) do
    Enum.with_index(batches, fn _batch, idx ->
      %{
        batch_index: idx,
        checkpoint_id: "batch_#{idx}_checkpoint",
        created_at: DateTime.utc_now()
      }
    end)
  end

  defp build_execution_context(type, opts) do
    %__MODULE__{
      execution_id: generate_execution_id(),
      mode: Keyword.get(opts, :mode, :dry_run),
      dry_run: Keyword.get(opts, :mode, :dry_run) == :dry_run,
      max_concurrent: Keyword.get(opts, :max_concurrent, @default_max_concurrent),
      timeout_ms: Keyword.get(opts, :timeout, @default_timeout_ms),
      create_checkpoints: Keyword.get(opts, :create_checkpoints, true),
      auto_rollback: Keyword.get(opts, :auto_rollback, true),
      rate_limit_per_minute: Keyword.get(opts, :rate_limit, @default_rate_limit),
      state_snapshots: %{},
      executed_actions: [],
      failed_actions: [],
      start_time: System.monotonic_time(:millisecond)
    }
  end

  defp execute_plan(execution, plan) do
    Logger.info("Executing optimization plan",
      execution_id: execution.execution_id,
      mode: execution.mode,
      dry_run: execution.dry_run,
      total_actions: plan.total_actions
    )

    if execution.dry_run do
      execute_dry_run(execution, plan)
    else
      execute_for_real(execution, plan)
    end
  end

  defp execute_dry_run(execution, plan) do
    Logger.info("DRY-RUN: Simulating execution", execution_id: execution.execution_id)

    simulated_actions =
      Enum.flat_map(plan.batches, fn batch ->
        Enum.map(batch, fn action ->
          %{
            action: action,
            status: :would_execute,
            estimated_duration_ms: 60_000,
            dry_run: true
          }
        end)
      end)

    duration_ms = System.monotonic_time(:millisecond) - execution.start_time

    result = %{
      success: true,
      executed_count: 0,
      failed_count: 0,
      rolled_back_count: 0,
      actions: simulated_actions,
      errors: [],
      duration_ms: duration_ms,
      dry_run: true
    }

    {:ok, result}
  end

  defp execute_for_real(execution, plan) do
    Logger.info("REAL EXECUTION: Applying optimizations", execution_id: execution.execution_id)

    result =
      Enum.reduce_while(
        plan.batches,
        %{executed: [], failed: [], snapshots: %{}},
        fn batch, acc ->
          case execute_batch(execution, batch, acc.snapshots) do
            {:ok, batch_result} ->
              {:cont,
               %{
                 executed: acc.executed ++ batch_result.executed,
                 failed: acc.failed ++ batch_result.failed,
                 snapshots: Map.merge(acc.snapshots, batch_result.snapshots)
               }}

            {:error, reason} ->
              if execution.auto_rollback do
                Logger.warn("Batch failed, initiating rollback",
                  execution_id: execution.execution_id,
                  reason: inspect(reason)
                )

                rollback_result = perform_rollback(acc.snapshots, [])
                {:halt, {:rollback_triggered, rollback_result}}
              else
                {:halt, {:failed, reason, acc}}
              end
          end
        end
      )

    duration_ms = System.monotonic_time(:millisecond) - execution.start_time

    case result do
      {:rollback_triggered, rollback_result} ->
        {:ok,
         %{
           success: false,
           executed_count: length(rollback_result[:executed] || []),
           failed_count: length(rollback_result[:failed] || []),
           rolled_back_count: rollback_result[:rolled_back_count] || 0,
           actions: rollback_result[:executed] || [],
           errors: rollback_result[:errors] || [],
           duration_ms: duration_ms,
           rollback_performed: true
         }}

      {:failed, reason, partial_result} ->
        {:error,
         %{
           reason: reason,
           partial_execution: partial_result,
           duration_ms: duration_ms
         }}

      %{executed: executed, failed: failed} ->
        success = Enum.empty?(failed)

        {:ok,
         %{
           success: success,
           executed_count: length(executed),
           failed_count: length(failed),
           rolled_back_count: 0,
           actions: executed,
           errors: failed,
           duration_ms: duration_ms,
           dry_run: false
         }}
    end
  end

  defp execute_batch(execution, batch, current_snapshots) do
    batch_checkpoint =
      if execution.create_checkpoints do
        create_batch_checkpoint(batch, current_snapshots)
      else
        current_snapshots
      end

    tasks =
      Enum.map(batch, fn action ->
        Task.async(fn ->
          apply_rate_limit(execution.rate_limit_per_minute)
          execute_action(action, execution)
        end)
      end)

    results = Task.await_many(tasks, execution.timeout_ms)

    {executed, failed} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    executed_actions = Enum.map(executed, fn {:ok, result} -> result end)
    failed_actions = Enum.map(failed, fn {:error, err} -> err end)

    if Enum.empty?(failed_actions) do
      {:ok,
       %{
         executed: executed_actions,
         failed: [],
         snapshots: batch_checkpoint
       }}
    else
      {:error, {:batch_failed, failed_actions}}
    end
  end

  defp execute_action(action, execution) do
    Logger.debug("Executing action",
      execution_id: execution.execution_id,
      action: action.type,
      machine: action[:machine_id]
    )

    case action.type do
      :migrate -> execute_migration(action)
      :rightsize -> execute_rightsizing(action)
      :consolidate -> execute_consolidation(action)
      :decommission -> execute_decommission(action)
      _ -> {:error, {:unknown_action_type, action.type}}
    end
  end

  defp execute_migration(%{machine_id: machine_id, target_region: target_region} = action) do
    strategy = Map.get(action, :strategy, "stop_and_move")

    Logger.info("Executing migration",
      machine_id: machine_id,
      target_region: target_region,
      strategy: strategy
    )

    case FlydClient.migrate_machine(machine_id, target_region, strategy: strategy) do
      {:ok, result} ->
        {:ok,
         %{
           action: :migrate,
           machine_id: machine_id,
           target_region: target_region,
           status: :completed,
           result: result
         }}

      {:error, reason} ->
        {:error,
         %{
           action: :migrate,
           machine_id: machine_id,
           reason: reason
         }}
    end
  end

  defp execute_rightsizing(%{machine_id: machine_id, target_specs: specs} = action) do
    Logger.info("Executing rightsizing",
      machine_id: machine_id,
      target_cpu: specs[:cpu],
      target_memory: specs[:memory_mb]
    )

    with {:ok, _} <- FlydClient.stop_machine(machine_id),
         {:ok, machine} <- update_machine_specs(machine_id, specs),
         {:ok, _} <- FlydClient.start_machine(machine_id) do
      {:ok,
       %{
         action: :rightsize,
         machine_id: machine_id,
         old_specs: action[:current_specs],
         new_specs: specs,
         status: :completed
       }}
    else
      {:error, reason} ->
        {:error,
         %{
           action: :rightsize,
           machine_id: machine_id,
           reason: reason
         }}
    end
  end

  defp execute_consolidation(%{machines_to_move: machines, target_host: target} = action) do
    Logger.info("Executing consolidation",
      machine_count: length(machines),
      target_host: target
    )

    results =
      Enum.map(machines, fn machine_id ->
        execute_migration(%{
          machine_id: machine_id,
          target_region: get_host_region(target),
          target_host: target,
          type: :migrate
        })
      end)

    {successful, failed} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    if Enum.empty?(failed) do
      {:ok,
       %{
         action: :consolidate,
         target_host: target,
         moved_machines: length(successful),
         status: :completed
       }}
    else
      {:error,
       %{
         action: :consolidate,
         partial_success: length(successful),
         failed: length(failed),
         errors: failed
       }}
    end
  end

  defp execute_decommission(%{host_id: host_id} = action) do
    Logger.info("Executing host decommission", host_id: host_id)

    case validate_host_empty(host_id) do
      :ok ->
        case decommission_host(host_id) do
          :ok ->
            {:ok,
             %{
               action: :decommission,
               host_id: host_id,
               status: :completed
             }}

          {:error, reason} ->
            {:error,
             %{
               action: :decommission,
               host_id: host_id,
               reason: reason
             }}
        end

      {:error, reason} ->
        {:error,
         %{
           action: :decommission,
           host_id: host_id,
           reason: reason,
           note: "Host not empty at execution time"
         }}
    end
  end

  defp maybe_create_checkpoint(recommendation, true = _create?) do
    checkpoint = %{
      checkpoint_id: generate_checkpoint_id(),
      recommendation: recommendation,
      created_at: DateTime.utc_now(),
      machine_state: capture_machine_state(recommendation[:machine_id])
    }

    store_checkpoint(checkpoint)
    {:ok, checkpoint}
  end

  defp maybe_create_checkpoint(_recommendation, false = _create?), do: {:ok, nil}

  defp create_batch_checkpoint(batch, current_snapshots) do
    batch_snapshot =
      Enum.reduce(batch, %{}, fn action, acc ->
        if machine_id = action[:machine_id] do
          state = capture_machine_state(machine_id)
          Map.put(acc, machine_id, state)
        else
          acc
        end
      end)

    Map.merge(current_snapshots, batch_snapshot)
  end

  defp capture_machine_state(machine_id) when is_binary(machine_id) do
    machine = Repo.get(Machine, machine_id)

    if machine do
      %{
        id: machine.id,
        region: machine.region,
        status: machine.status,
        metadata: machine.metadata,
        version: machine.version,
        captured_at: DateTime.utc_now()
      }
    else
      nil
    end
  end

  defp capture_machine_state(_), do: nil

  defp store_checkpoint(checkpoint) do
    Logger.debug("Storing checkpoint", checkpoint_id: checkpoint.checkpoint_id)
    :ok
  end

  defp load_execution_checkpoints(execution_id) do
    Logger.debug("Loading checkpoints", execution_id: execution_id)
    {:ok, %{}}
  end

  defp perform_rollback(snapshots, _opts) when map_size(snapshots) == 0 do
    {:ok, %{rolled_back_count: 0, errors: []}}
  end

  defp perform_rollback(snapshots, _opts) do
    Logger.warn("Performing rollback", machine_count: map_size(snapshots))

    results =
      Enum.map(snapshots, fn {machine_id, snapshot} ->
        restore_machine_state(machine_id, snapshot)
      end)

    {successful, failed} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    {:ok,
     %{
       rolled_back_count: length(successful),
       errors: Enum.map(failed, fn {:error, err} -> err end)
     }}
  end

  defp restore_machine_state(machine_id, snapshot) do
    Logger.info("Restoring machine state",
      machine_id: machine_id,
      snapshot_time: snapshot.captured_at
    )

    machine = Repo.get(Machine, machine_id)

    if machine do
      changeset =
        Ecto.Changeset.change(machine, %{
          region: snapshot.region,
          status: snapshot.status,
          metadata: snapshot.metadata
        })

      case Repo.update(changeset) do
        {:ok, restored} ->
          {:ok, restored}

        {:error, changeset} ->
          {:error, {:restore_failed, changeset.errors}}
      end
    else
      {:error, {:machine_not_found, machine_id}}
    end
  end

  defp do_execute_placement(recommendation) do
    execute_action(recommendation, %__MODULE__{
      execution_id: generate_execution_id(),
      mode: :direct,
      dry_run: false,
      timeout_ms: @default_timeout_ms
    })
  end

  defp update_machine_specs(machine_id, specs) do
    machine = Repo.get!(Machine, machine_id)

    metadata =
      Map.merge(machine.metadata || %{}, %{
        "cpu" => to_string(specs[:cpu]),
        "memory_mb" => to_string(specs[:memory_mb]),
        "updated_by" => "placement_executor",
        "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    changeset = Ecto.Changeset.change(machine, metadata: metadata)

    case Repo.update(changeset) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, changeset.errors}
    end
  end

  defp get_host_region(_host_id) do
    "us-east-1"
  end

  defp decommission_host(_host_id) do
    Logger.info("Host decommissioned (simulated)")
    :ok
  end

  defp get_host_available_capacity(_host_id) do
    50
  end

  defp apply_rate_limit(limit_per_minute) do
    delay_ms = trunc(60_000 / limit_per_minute)
    Process.sleep(delay_ms)
  end

  defp audit_placement_execution(recommendation, result, checkpoint) do
    event_data = %{
      recommendation: recommendation,
      result: result,
      checkpoint_id: checkpoint && checkpoint.checkpoint_id,
      executed_at: DateTime.utc_now()
    }

    EventWriter.append_event(
      recommendation[:machine_id] || "system",
      :placement_executed,
      event_data,
      actor: "placement_executor"
    )
  end

  defp log_execution_result(optimization_type, result) do
    Logger.info("Optimization execution complete",
      type: optimization_type,
      success: result.success,
      executed: result.executed_count,
      failed: result.failed_count,
      rolled_back: result.rolled_back_count,
      duration_ms: result.duration_ms,
      dry_run: Map.get(result, :dry_run, false)
    )

    :telemetry.execute(
      [:orchestrator, :placement, :execution, :complete],
      %{
        executed: result.executed_count,
        failed: result.failed_count,
        duration_ms: result.duration_ms
      },
      %{
        optimization_type: optimization_type,
        success: result.success
      }
    )
  end

  defp generate_execution_id do
    ("exec_" <> :crypto.strong_rand_bytes(16)) |> Base.encode16(case: :lower)
  end

  defp generate_checkpoint_id do
    ("ckpt_" <> :crypto.strong_rand_bytes(12)) |> Base.encode16(case: :lower)
  end
end
