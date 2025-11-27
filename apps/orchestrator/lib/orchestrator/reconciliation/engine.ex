defmodule Orchestrator.Reconciliation.Engine do
  use GenServer
  require Logger
  alias Orchestrator.{Repo, Machine, FlydClient}
  alias Orchestrator.Reconciliation.{DriftAnalyzer, AutoHealer}
  @type reconciliation_level :: :basic | :standard | :deep | :paranoid
  @type healing_strategy :: :auto | :manual | :rollback
  @type drift_severity :: :critical | :major | :minor | :none
  @type reconciliation_config :: %{
          level: reconciliation_level(),
          healing_strategy: healing_strategy(),
          auto_heal_threshold: drift_severity(),
          verify_checksums: boolean(),
          parallel_workers: pos_integer(),
          timeout_ms: pos_integer(),
          retry_attempts: non_neg_integer()
        }
  @type reconciliation_result :: %{
          machine_id: String.t(),
          status: :success | :failure | :partial,
          drift_detected: boolean(),
          drift_severity: drift_severity(),
          inconsistencies: [map()],
          healing_actions: [map()],
          duration_ms: non_neg_integer(),
          timestamp: DateTime.t()
        }
  @default_config %{
    level: :standard,
    healing_strategy: :auto,
    auto_heal_threshold: :minor,
    verify_checksums: true,
    parallel_workers: 4,
    timeout_ms: 60_000,
    retry_attempts: 3
  }
  @reconciliation_interval 30_000
  @checkpoint_interval 100
  defmodule State do
    defstruct [
      :config,
      :active_reconciliations,
      :reconciliation_history,
      :checkpoint_data,
      :statistics,
      :worker_pool,
      :timer_ref
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec reconcile_machine(String.t(), keyword()) ::
          {:ok, reconciliation_result()} | {:error, term()}
  def reconcile_machine(machine_id, opts \\ []) do
    GenServer.call(__MODULE__, {:reconcile_machine, machine_id, opts}, :infinity)
  end

  @spec reconcile_region(String.t(), keyword()) ::
          {:ok, [reconciliation_result()]} | {:error, term()}
  def reconcile_region(region, opts \\ []) do
    GenServer.call(__MODULE__, {:reconcile_region, region, opts}, :infinity)
  end

  @spec reconcile_recent_migrations(keyword()) ::
          {:ok, [reconciliation_result()]} | {:error, term()}
  def reconcile_recent_migrations(opts \\ []) do
    GenServer.call(__MODULE__, {:reconcile_recent_migrations, opts}, :infinity)
  end

  @spec get_statistics() :: map()
  def get_statistics do
    GenServer.call(__MODULE__, :get_statistics)
  end

  @spec get_history(String.t(), keyword()) :: [reconciliation_result()]
  def get_history(machine_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_history, machine_id, opts})
  end

  @spec trigger_reconciliation() :: :ok
  def trigger_reconciliation do
    GenServer.cast(__MODULE__, :trigger_reconciliation)
  end

  @spec update_config(map()) :: :ok
  def update_config(config_updates) do
    GenServer.call(__MODULE__, {:update_config, config_updates})
  end

  @impl true
  def init(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    state = %State{
      config: config,
      active_reconciliations: %{},
      reconciliation_history: :ets.new(:reconciliation_history, [:ordered_set, :private]),
      checkpoint_data: load_checkpoint(),
      statistics: initialize_statistics(),
      worker_pool: initialize_worker_pool(config.parallel_workers),
      timer_ref: nil
    }

    timer_ref = Process.send_after(self(), :periodic_reconciliation, @reconciliation_interval)
    state = %{state | timer_ref: timer_ref}

    Logger.info("Reconciliation engine started",
      config: config,
      workers: config.parallel_workers
    )

    :telemetry.execute(
      [:orchestrator, :reconciliation, :engine, :started],
      %{},
      %{config: config}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:reconcile_machine, machine_id, opts}, from, state) do
    config = merge_config(state.config, opts)

    case get_machine_for_reconciliation(machine_id) do
      {:ok, machine} ->
        task =
          Task.async(fn ->
            execute_reconciliation(machine, config, state)
          end)

        active =
          Map.put(
            state.active_reconciliations,
            machine_id,
            {task, from, System.monotonic_time(:millisecond)}
          )

        {:noreply, %{state | active_reconciliations: active}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:reconcile_region, region, opts}, _from, state) do
    config = merge_config(state.config, opts)
    machines = get_machines_in_region(region)

    Logger.info("Starting region reconciliation",
      region: region,
      machine_count: length(machines),
      level: config.level
    )

    results =
      machines
      |> Task.async_stream(
        fn machine -> execute_reconciliation(machine, config, state) end,
        max_concurrency: config.parallel_workers,
        timeout: config.timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:task_killed, reason}}
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    failure_count = length(results) - success_count

    :telemetry.execute(
      [:orchestrator, :reconciliation, :region, :completed],
      %{success_count: success_count, failure_count: failure_count},
      %{region: region, total: length(results)}
    )

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call({:reconcile_recent_migrations, opts}, _from, state) do
    config = merge_config(state.config, opts)
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)
    machines = get_recently_migrated_machines(cutoff)

    Logger.info("Reconciling recent migrations",
      machine_count: length(machines),
      since: cutoff
    )

    results =
      machines
      |> Task.async_stream(
        fn machine -> execute_reconciliation(machine, config, state) end,
        max_concurrency: config.parallel_workers,
        timeout: config.timeout_ms
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:timeout, reason}}
      end)

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call(:get_statistics, _from, state) do
    stats =
      Map.merge(state.statistics, %{
        active_reconciliations: map_size(state.active_reconciliations),
        worker_pool_size: length(state.worker_pool),
        checkpoint_count: map_size(state.checkpoint_data)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_history, machine_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)

    history =
      :ets.select(state.reconciliation_history, [
        {{:"$1", :"$2"}, [{:==, :"$1", machine_id}], [:"$2"]}
      ])
      |> Enum.take(limit)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    {:reply, history, state}
  end

  @impl true
  def handle_call({:update_config, config_updates}, _from, state) do
    new_config = Map.merge(state.config, config_updates)

    Logger.info("Reconciliation config updated",
      old_config: state.config,
      new_config: new_config
    )

    {:reply, :ok, %{state | config: new_config}}
  end

  @impl true
  def handle_cast(:trigger_reconciliation, state) do
    send(self(), :periodic_reconciliation)
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_reconciliation, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    spawn(fn -> periodic_reconciliation_cycle(state.config) end)
    timer_ref = Process.send_after(self(), :periodic_reconciliation, @reconciliation_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Enum.find(state.active_reconciliations, fn {_id, {task, _from, _start}} ->
           task.ref == ref
         end) do
      {machine_id, {_task, from, start_time}} ->
        duration = System.monotonic_time(:millisecond) - start_time
        GenServer.reply(from, result)

        if match?({:ok, _}, result) do
          {:ok, reconciliation_result} = result
          store_reconciliation_result(state, machine_id, reconciliation_result, duration)
        end

        new_stats = update_statistics(state.statistics, result, duration)
        active = Map.delete(state.active_reconciliations, machine_id)
        {:noreply, %{state | active_reconciliations: active, statistics: new_stats}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("Reconciliation task died", reason: reason)
    {:noreply, state}
  end

  defp execute_reconciliation(machine, config, _state) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Starting reconciliation for machine #{machine.id}",
      level: config.level,
      healing: config.healing_strategy
    )

    :telemetry.execute(
      [:orchestrator, :reconciliation, :started],
      %{},
      %{machine_id: machine.id, level: config.level}
    )

    result =
      with {:ok, source_state} <- fetch_source_state(machine, config),
           {:ok, target_state} <- fetch_target_state(machine, config),
           {:ok, diff_analysis} <- analyze_state_diff(source_state, target_state, config),
           {:ok, healing_result} <- apply_healing_if_needed(machine, diff_analysis, config) do
        duration_ms = System.monotonic_time(:millisecond) - start_time

        reconciliation_result = %{
          machine_id: machine.id,
          status: determine_status(diff_analysis, healing_result),
          drift_detected: diff_analysis.has_drift,
          drift_severity: diff_analysis.severity,
          inconsistencies: diff_analysis.inconsistencies,
          healing_actions: healing_result.actions,
          duration_ms: duration_ms,
          timestamp: DateTime.utc_now(),
          metadata: %{
            source_region: source_state.region,
            target_region: target_state.region,
            reconciliation_level: config.level,
            healing_strategy: config.healing_strategy
          }
        }

        Logger.info("Reconciliation completed for machine #{machine.id}",
          status: reconciliation_result.status,
          drift: diff_analysis.has_drift,
          severity: diff_analysis.severity,
          duration_ms: duration_ms
        )

        :telemetry.execute(
          [:orchestrator, :reconciliation, :completed],
          %{duration_ms: duration_ms, drift_count: length(diff_analysis.inconsistencies)},
          %{machine_id: machine.id, status: reconciliation_result.status}
        )

        {:ok, reconciliation_result}
      else
        {:error, reason} = error ->
          duration_ms = System.monotonic_time(:millisecond) - start_time

          Logger.error("Reconciliation failed for machine #{machine.id}",
            reason: inspect(reason),
            duration_ms: duration_ms
          )

          :telemetry.execute(
            [:orchestrator, :reconciliation, :failed],
            %{duration_ms: duration_ms},
            %{machine_id: machine.id, reason: reason}
          )

          error
      end

    result
  end

  defp fetch_source_state(machine, config) do
    source_region = Map.get(machine.metadata, "source_region") || machine.region

    case FlydClient.get_machine_state(machine.id, region: source_region, level: config.level) do
      {:ok, state} ->
        {:ok, Map.put(state, :region, source_region)}

      {:error, reason} ->
        Logger.warning("Failed to fetch source state for machine #{machine.id}",
          region: source_region,
          reason: inspect(reason)
        )

        {:error, {:source_state_fetch_failed, reason}}
    end
  end

  defp fetch_target_state(machine, config) do
    target_region = Map.get(machine.metadata, "target_region") || machine.region

    case FlydClient.get_machine_state(machine.id, region: target_region, level: config.level) do
      {:ok, state} ->
        {:ok, Map.put(state, :region, target_region)}

      {:error, reason} ->
        Logger.error("Failed to fetch target state for machine #{machine.id}",
          region: target_region,
          reason: inspect(reason)
        )

        {:error, {:target_state_fetch_failed, reason}}
    end
  end

  defp analyze_state_diff(source_state, target_state, config) do
    case DriftAnalyzer.analyze(source_state, target_state, config) do
      {:ok, analysis} -> {:ok, analysis}
      error -> error
    end
  end

  defp apply_healing_if_needed(machine, diff_analysis, config) do
    if diff_analysis.has_drift and should_auto_heal?(diff_analysis, config) do
      Logger.info("Applying auto-healing for machine #{machine.id}",
        severity: diff_analysis.severity,
        inconsistency_count: length(diff_analysis.inconsistencies)
      )

      AutoHealer.heal(machine, diff_analysis, config)
    else
      {:ok, %{actions: [], status: :no_healing_needed}}
    end
  end

  defp should_auto_heal?(diff_analysis, config) do
    config.healing_strategy == :auto and
      severity_exceeds_threshold?(diff_analysis.severity, config.auto_heal_threshold)
  end

  defp severity_exceeds_threshold?(:critical, _), do: true
  defp severity_exceeds_threshold?(:major, threshold) when threshold in [:major, :minor], do: true
  defp severity_exceeds_threshold?(:minor, :minor), do: true
  defp severity_exceeds_threshold?(_, _), do: false

  defp determine_status(diff_analysis, healing_result) do
    cond do
      not diff_analysis.has_drift -> :success
      healing_result.status == :fully_healed -> :success
      healing_result.status == :partially_healed -> :partial
      true -> :failure
    end
  end

  defp get_machine_for_reconciliation(machine_id) do
    case Repo.get(Machine, machine_id) do
      nil -> {:error, :machine_not_found}
      machine -> {:ok, machine}
    end
  end

  defp get_machines_in_region(region) do
    import Ecto.Query

    from(m in Machine,
      where: m.region == ^region and m.status != "destroyed",
      select: m
    )
    |> Repo.all()
  end

  defp get_recently_migrated_machines(since_datetime) do
    import Ecto.Query

    from(m in Machine,
      where:
        m.status != "destroyed" and
          fragment("?->>'last_migration_at' IS NOT NULL", m.metadata) and
          fragment("(?->>'last_migration_at')::timestamp > ?", m.metadata, ^since_datetime),
      select: m
    )
    |> Repo.all()
  end

  defp periodic_reconciliation_cycle(config) do
    machines = get_machines_needing_reconciliation(config)

    Logger.debug("Periodic reconciliation cycle",
      machine_count: length(machines)
    )

    Enum.each(machines, fn machine ->
      Task.start(fn ->
        case execute_reconciliation(machine, config, %{}) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Logger.debug("Periodic reconciliation skipped for #{machine.id}",
              reason: inspect(reason)
            )
        end
      end)
    end)
  end

  defp get_machines_needing_reconciliation(_config) do
    import Ecto.Query
    cutoff_migration = DateTime.add(DateTime.utc_now(), -86400, :second)
    cutoff_reconciliation = DateTime.add(DateTime.utc_now(), -1800, :second)

    from(m in Machine,
      where:
        m.status == "running" and
          (fragment("?->>'last_migration_at' IS NOT NULL", m.metadata) and
             fragment("(?->>'last_migration_at')::timestamp > ?", m.metadata, ^cutoff_migration) and
             (fragment("?->>'last_reconciliation_at' IS NULL", m.metadata) or
                fragment(
                  "(?->>'last_reconciliation_at')::timestamp < ?",
                  m.metadata,
                  ^cutoff_reconciliation
                ))),
      limit: 50,
      select: m
    )
    |> Repo.all()
  end

  defp initialize_statistics do
    %{
      total_reconciliations: 0,
      successful_reconciliations: 0,
      failed_reconciliations: 0,
      partial_reconciliations: 0,
      total_drift_detected: 0,
      total_healing_actions: 0,
      average_duration_ms: 0,
      last_reconciliation_at: nil
    }
  end

  defp update_statistics(stats, result, duration_ms) do
    new_stats = %{
      stats
      | total_reconciliations: stats.total_reconciliations + 1,
        last_reconciliation_at: DateTime.utc_now()
    }

    new_stats =
      case result do
        {:ok, %{status: :success}} ->
          %{new_stats | successful_reconciliations: stats.successful_reconciliations + 1}

        {:ok, %{status: :partial}} ->
          %{new_stats | partial_reconciliations: stats.partial_reconciliations + 1}

        _ ->
          %{new_stats | failed_reconciliations: stats.failed_reconciliations + 1}
      end

    new_stats =
      if match?({:ok, %{drift_detected: true}}, result) do
        %{new_stats | total_drift_detected: stats.total_drift_detected + 1}
      else
        new_stats
      end

    alpha = 0.2
    avg_duration = stats.average_duration_ms * (1 - alpha) + duration_ms * alpha
    %{new_stats | average_duration_ms: avg_duration}
  end

  defp store_reconciliation_result(state, machine_id, result, _duration) do
    :ets.insert(state.reconciliation_history, {machine_id, result})

    if rem(state.statistics.total_reconciliations + 1, @checkpoint_interval) == 0 do
      save_checkpoint(state)
    end
  end

  defp initialize_worker_pool(count) do
    Enum.map(1..count, fn i ->
      {:ok, pid} = Task.Supervisor.start_link()
      {i, pid}
    end)
  end

  defp merge_config(base_config, opts) do
    opts_map = Map.new(opts)
    Map.merge(base_config, opts_map)
  end

  defp load_checkpoint do
    %{}
  end

  defp save_checkpoint(_state) do
    :ok
  end
end
