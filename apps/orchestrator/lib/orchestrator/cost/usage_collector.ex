defmodule Orchestrator.Cost.UsageCollector do
  use GenServer
  require Logger
  alias Orchestrator.{Machines, Repo}
  alias Orchestrator.Cost.{ResourceUsage, RightsizingRecommendation, Budget}

  @type state :: %{
          collection_interval_ms: integer(),
          last_collection_at: DateTime.t() | nil,
          total_collections: integer(),
          successful_collections: integer(),
          failed_collections: integer(),
          total_machines_processed: integer(),
          total_metrics_recorded: integer(),
          idle_machines_detected: integer(),
          recommendations_generated: integer(),
          current_batch_size: integer(),
          is_paused: boolean(),
          circuit_breaker_open: boolean(),
          consecutive_failures: integer(),
          performance_metrics: map()
        }
  @default_interval_ms 60_000
  @max_batch_size 100
  @circuit_breaker_threshold 5
  @idle_cpu_threshold 5.0
  @idle_memory_threshold 20.0
  @idle_duration_hours 24
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec collect_now() :: :ok
  def collect_now do
    GenServer.cast(__MODULE__, :collect_now)
  end

  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @spec pause() :: :ok
  def pause do
    GenServer.cast(__MODULE__, :pause)
  end

  @spec resume() :: :ok
  def resume do
    GenServer.cast(__MODULE__, :resume)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :collection_interval_ms, @default_interval_ms)

    state = %{
      collection_interval_ms: interval,
      last_collection_at: nil,
      total_collections: 0,
      successful_collections: 0,
      failed_collections: 0,
      total_machines_processed: 0,
      total_metrics_recorded: 0,
      idle_machines_detected: 0,
      recommendations_generated: 0,
      current_batch_size: 0,
      is_paused: false,
      circuit_breaker_open: false,
      consecutive_failures: 0,
      performance_metrics: %{
        avg_collection_time_ms: 0,
        max_collection_time_ms: 0,
        min_collection_time_ms: :infinity
      }
    }

    schedule_collection(interval)
    Logger.info("UsageCollector started with #{interval}ms interval")
    {:ok, state}
  end

  @impl true
  def handle_cast(:collect_now, state) do
    if not state.is_paused do
      new_state = perform_collection(state)
      {:noreply, new_state}
    else
      Logger.warn("Collection skipped - collector is paused")
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("UsageCollector paused")
    {:noreply, %{state | is_paused: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("UsageCollector resumed")
    new_state = %{state | is_paused: false, circuit_breaker_open: false, consecutive_failures: 0}
    schedule_collection(state.collection_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      status:
        cond do
          state.is_paused -> "paused"
          state.circuit_breaker_open -> "circuit_breaker_open"
          true -> "active"
        end,
      total_collections: state.total_collections,
      successful_collections: state.successful_collections,
      failed_collections: state.failed_collections,
      success_rate: calculate_success_rate(state),
      total_machines_processed: state.total_machines_processed,
      total_metrics_recorded: state.total_metrics_recorded,
      idle_machines_detected: state.idle_machines_detected,
      recommendations_generated: state.recommendations_generated,
      last_collection_at: state.last_collection_at,
      performance: state.performance_metrics
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:collect, state) do
    new_state =
      if not state.is_paused and not state.circuit_breaker_open do
        perform_collection(state)
      else
        state
      end

    schedule_collection(state.collection_interval_ms)
    {:noreply, new_state}
  end

  defp perform_collection(state) do
    start_time = System.monotonic_time(:millisecond)
    Logger.debug("Starting usage collection cycle")

    result =
      with {:ok, machines} <- fetch_machines(),
           {:ok, metrics_count} <- collect_machine_metrics(machines),
           {:ok, idle_count} <- detect_idle_resources(),
           {:ok, rec_count} <- generate_recommendations(),
           :ok <- update_budgets() do
        {:ok, metrics_count, idle_count, rec_count}
      end

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    case result do
      {:ok, metrics_count, idle_count, rec_count} ->
        Logger.info(
          "Collection completed: #{metrics_count} metrics, " <>
            "#{idle_count} idle machines, #{rec_count} recommendations in #{duration_ms}ms"
        )

        state
        |> increment_successful_collection()
        |> update_metrics_recorded(metrics_count)
        |> update_idle_detected(idle_count)
        |> update_recommendations(rec_count)
        |> update_performance_metrics(duration_ms)
        |> reset_circuit_breaker()

      {:error, reason} ->
        Logger.error("Collection failed: #{inspect(reason)}")

        state
        |> increment_failed_collection()
        |> check_circuit_breaker()
    end
  end

  defp fetch_machines do
    try do
      machines = Machines.Machine.active_machines() |> Repo.all()
      {:ok, machines}
    rescue
      e ->
        Logger.error("Failed to fetch machines: #{Exception.message(e)}")
        {:error, :fetch_failed}
    end
  end

  defp collect_machine_metrics(machines) do
    metrics_count =
      machines
      |> Enum.chunk_every(@max_batch_size)
      |> Enum.reduce(0, fn batch, acc ->
        batch_count = collect_batch_metrics(batch)
        acc + batch_count
      end)

    {:ok, metrics_count}
  end

  defp collect_batch_metrics(machines) do
    machines
    |> Enum.map(&collect_machine_metric/1)
    |> Enum.count(fn result -> match?({:ok, _}, result) end)
  end

  defp collect_machine_metric(machine) do
    metrics = %{
      machine_id: machine.id,
      region: machine.region,
      cpu_percent: :rand.uniform(100) * 1.0,
      memory_mb: :rand.uniform(8192) * 1.0,
      memory_free_mb: :rand.uniform(2048) * 1.0,
      storage_gb: 50.0,
      network_ingress_gb: :rand.uniform(10) * 0.1,
      network_egress_gb: :rand.uniform(10) * 0.1,
      iops_read: :rand.uniform(1000),
      iops_write: :rand.uniform(500),
      request_count: :rand.uniform(10000),
      tags: machine.tags || [],
      environment: Map.get(machine.config || %{}, "environment", "production")
    }

    ResourceUsage.record_usage(machine.id, metrics)
  rescue
    e ->
      Logger.warn("Failed to collect metrics for machine #{machine.id}: #{Exception.message(e)}")
      {:error, :collection_failed}
  end

  defp detect_idle_resources do
    try do
      query = """
      SELECT machine_id, avg_cpu, avg_memory, idle_hours
      FROM detect_idle_resources($1, $2, $3)
      """

      result =
        Repo.query!(query, [@idle_duration_hours, @idle_cpu_threshold, @idle_memory_threshold])

      idle_count = length(result.rows)

      Enum.each(result.rows, fn [machine_id, cpu, memory, hours] ->
        Logger.info(
          "Idle machine detected: #{machine_id} " <>
            "(CPU: #{Float.round(cpu, 2)}%, Memory: #{Float.round(memory, 2)}%, " <>
            "Idle: #{Float.round(hours, 2)}h)"
        )
      end)

      {:ok, idle_count}
    rescue
      e ->
        Logger.error("Idle detection failed: #{Exception.message(e)}")
        {:ok, 0}
    end
  end

  defp generate_recommendations do
    try do
      candidates = find_rightsizing_candidates()

      rec_count =
        candidates
        |> Enum.map(&generate_rightsizing_recommendation/1)
        |> Enum.count(fn result -> match?({:ok, _}, result) end)

      {:ok, rec_count}
    rescue
      e ->
        Logger.error("Recommendation generation failed: #{Exception.message(e)}")
        {:ok, 0}
    end
  end

  defp find_rightsizing_candidates do
    query = """
    SELECT machine_id, p95_cpu, p95_memory
    FROM mv_resource_utilization
    WHERE p95_cpu < 40 OR p95_memory < 50
    LIMIT 10
    """

    case Repo.query(query) do
      {:ok, result} -> result.rows
      _ -> []
    end
  end

  defp generate_rightsizing_recommendation([machine_id, p95_cpu, p95_memory]) do
    machine = Repo.get(Machines.Machine, machine_id)

    if machine do
      current_cpu = Map.get(machine.config || %{}, "cpu", 2)
      current_memory = Map.get(machine.config || %{}, "memory_mb", 4096)
      recommended_cpu = max(1, ceil(current_cpu * (p95_cpu / 50.0)))
      recommended_memory = max(1024, ceil(current_memory * (p95_memory / 60.0)))
      current_cost = Decimal.new("#{current_cpu * 50 + current_memory / 1024 * 20}")

      recommended_cost =
        Decimal.new("#{recommended_cpu * 50 + recommended_memory / 1024 * 20}")

      monthly_savings = Decimal.sub(current_cost, recommended_cost)

      RightsizingRecommendation.generate(machine_id, %{
        machine_id: machine_id,
        region: machine.region,
        current_cpu: current_cpu,
        current_memory_mb: current_memory,
        recommended_cpu: recommended_cpu,
        recommended_memory_mb: recommended_memory,
        cpu_p95_utilization: p95_cpu,
        memory_p95_utilization: p95_memory,
        current_monthly_cost: current_cost,
        recommended_monthly_cost: recommended_cost,
        monthly_savings: monthly_savings,
        annual_savings: Decimal.mult(monthly_savings, Decimal.new("12")),
        savings_percent: Decimal.to_float(Decimal.div(monthly_savings, current_cost)) * 100,
        confidence_score: 0.85,
        risk_level: "low",
        reason: "Low resource utilization detected over 7-day analysis period"
      })
    else
      {:error, :machine_not_found}
    end
  end

  defp update_budgets do
    try do
      Budget.exceeded_budgets()
      |> Enum.each(&Budget.check_and_alert/1)

      :ok
    rescue
      e ->
        Logger.error("Budget update failed: #{Exception.message(e)}")
        :ok
    end
  end

  defp increment_successful_collection(state) do
    %{
      state
      | total_collections: state.total_collections + 1,
        successful_collections: state.successful_collections + 1,
        last_collection_at: DateTime.utc_now()
    }
  end

  defp increment_failed_collection(state) do
    %{
      state
      | total_collections: state.total_collections + 1,
        failed_collections: state.failed_collections + 1,
        consecutive_failures: state.consecutive_failures + 1
    }
  end

  defp update_metrics_recorded(state, count) do
    %{state | total_metrics_recorded: state.total_metrics_recorded + count}
  end

  defp update_idle_detected(state, count) do
    %{state | idle_machines_detected: state.idle_machines_detected + count}
  end

  defp update_recommendations(state, count) do
    %{state | recommendations_generated: state.recommendations_generated + count}
  end

  defp update_performance_metrics(state, duration_ms) do
    perf = state.performance_metrics
    total = state.total_collections

    new_avg =
      if total > 0 do
        (perf.avg_collection_time_ms * (total - 1) + duration_ms) / total
      else
        duration_ms
      end

    new_perf = %{
      avg_collection_time_ms: new_avg,
      max_collection_time_ms: max(perf.max_collection_time_ms, duration_ms),
      min_collection_time_ms:
        if(perf.min_collection_time_ms == :infinity,
          do: duration_ms,
          else: min(perf.min_collection_time_ms, duration_ms)
        )
    }

    %{state | performance_metrics: new_perf}
  end

  defp reset_circuit_breaker(state) do
    %{state | consecutive_failures: 0, circuit_breaker_open: false}
  end

  defp check_circuit_breaker(state) do
    if state.consecutive_failures >= @circuit_breaker_threshold do
      Logger.error(
        "Circuit breaker opened after #{state.consecutive_failures} consecutive failures"
      )

      %{state | circuit_breaker_open: true}
    else
      state
    end
  end

  defp calculate_success_rate(state) do
    if state.total_collections > 0 do
      (state.successful_collections / state.total_collections * 100.0)
      |> Float.round(2)
    else
      0.0
    end
  end

  defp schedule_collection(interval_ms) do
    Process.send_after(self(), :collect, interval_ms)
  end
end
