defmodule Orchestrator.Recovery.Reconciler do
  use GenServer
  require Logger

  alias Orchestrator.Recovery.{DriftDetector, RepairActions}

  @reconciliation_interval_ms 60_000
  @max_concurrent_repairs 10
  @max_retry_attempts 3

  defstruct [
    :timer_ref,
    :stats,
    :retry_tracker,
    :repair_queue,
    :config
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def force_reconciliation do
    GenServer.call(__MODULE__, :force_reconciliation, :infinity)
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  def retry_repair(machine_id) do
    GenServer.call(__MODULE__, {:retry_repair, machine_id})
  end

  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @reconciliation_interval_ms)
    auto_start = Keyword.get(opts, :auto_start, true)
    enable_auto_repair = Keyword.get(opts, :enable_auto_repair, true)

    state = %__MODULE__{
      timer_ref: nil,
      stats: %{
        started_at: DateTime.utc_now(),
        last_run: nil,
        total_cycles: 0,
        total_anomalies_found: 0,
        total_repairs_attempted: 0,
        total_repairs_succeeded: 0,
        total_repairs_failed: 0,
        failed_machines: MapSet.new()
      },
      retry_tracker: %{},
      repair_queue: :queue.new(),
      config: %{
        interval_ms: interval_ms,
        max_concurrent_repairs: @max_concurrent_repairs,
        enable_auto_repair: enable_auto_repair,
        paused: false
      }
    }

    Logger.info("Reconciler started",
      interval_ms: interval_ms,
      auto_repair: enable_auto_repair
    )

    if auto_start do
      {:ok, schedule_next_cycle(state)}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:force_reconciliation, _from, state) do
    Logger.info("Force reconciliation triggered")

    {result, new_state} = execute_reconciliation_cycle(state)

    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    uptime_seconds =
      DateTime.diff(DateTime.utc_now(), state.stats.started_at, :second)

    stats = Map.put(state.stats, :uptime_seconds, uptime_seconds)

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:retry_repair, machine_id}, _from, state) do
    Logger.info("Manual retry requested", machine_id: machine_id)

    case DriftDetector.check_machine(machine_id) do
      {:ok, :healthy} ->
        {:reply, {:ok, :already_healthy}, state}

      {:ok, {:anomaly, anomaly}} ->
        {result, new_state} = repair_anomaly(anomaly, state)
        {:reply, result, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("Reconciler paused")

    new_state =
      if state.timer_ref do
        Process.cancel_timer(state.timer_ref)
        put_in(state.config.paused, true)
      else
        put_in(state.config.paused, true)
      end

    {:reply, :ok, %{new_state | timer_ref: nil}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Logger.info("Reconciler resumed")

    new_state =
      state
      |> put_in([:config, :paused], false)
      |> schedule_next_cycle()

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:reconciliation_cycle, state) do
    if state.config.paused do
      {:noreply, schedule_next_cycle(state)}
    else
      {_result, new_state} = execute_reconciliation_cycle(state)

      {:noreply, schedule_next_cycle(new_state)}
    end
  end

  @impl true
  def handle_info({:repair_complete, machine_id, result}, state) do
    Logger.debug("Repair completed async", machine_id: machine_id, result: result)

    new_state =
      case result do
        :ok ->
          update_in(state.stats.total_repairs_succeeded, &(&1 + 1))

        {:error, _reason} ->
          state
          |> update_in([:stats, :total_repairs_failed], &(&1 + 1))
          |> update_in([:stats, :failed_machines], &MapSet.put(&1, machine_id))
      end

    {:noreply, new_state}
  end

  defp execute_reconciliation_cycle(state) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Starting reconciliation cycle",
      cycle: state.stats.total_cycles + 1
    )

    case DriftDetector.detect_drift() do
      {:ok, drift_report} ->
        anomaly_count = length(drift_report.anomalies)

        Logger.info("Drift detection complete",
          anomalies_found: anomaly_count,
          summary: drift_report.summary
        )

        repair_results =
          if state.config.enable_auto_repair && anomaly_count > 0 do
            repair_anomalies(drift_report.anomalies, state)
          else
            []
          end

        duration_ms = System.monotonic_time(:millisecond) - start_time

        repairs_attempted = length(repair_results)

        repairs_succeeded =
          Enum.count(repair_results, fn
            {:ok, _} -> true
            _ -> false
          end)

        repairs_failed = repairs_attempted - repairs_succeeded

        new_stats = %{
          state.stats
          | last_run: DateTime.utc_now(),
            total_cycles: state.stats.total_cycles + 1,
            total_anomalies_found: state.stats.total_anomalies_found + anomaly_count,
            total_repairs_attempted: state.stats.total_repairs_attempted + repairs_attempted,
            total_repairs_succeeded: state.stats.total_repairs_succeeded + repairs_succeeded,
            total_repairs_failed: state.stats.total_repairs_failed + repairs_failed
        }

        :telemetry.execute(
          [:orchestrator, :reconciler, :cycle_complete],
          %{
            duration_ms: duration_ms,
            anomalies_found: anomaly_count,
            repairs_attempted: repairs_attempted,
            repairs_succeeded: repairs_succeeded,
            repairs_failed: repairs_failed
          },
          %{node: node()}
        )

        Logger.info("Reconciliation cycle complete",
          duration_ms: duration_ms,
          anomalies_found: anomaly_count,
          repairs_attempted: repairs_attempted,
          repairs_succeeded: repairs_succeeded,
          repairs_failed: repairs_failed
        )

        result = %{
          drift_report: drift_report,
          repair_results: repair_results,
          duration_ms: duration_ms
        }

        {result, %{state | stats: new_stats}}

      {:error, reason} ->
        Logger.error("Drift detection failed", reason: inspect(reason))

        :telemetry.execute(
          [:orchestrator, :reconciler, :cycle_failed],
          %{count: 1},
          %{node: node(), reason: reason}
        )

        {%{error: reason}, state}
    end
  end

  defp repair_anomalies(anomalies, state) do
    sorted_anomalies =
      Enum.sort_by(anomalies, fn anomaly ->
        case anomaly.severity do
          :critical -> 1
          :high -> 2
          :medium -> 3
          :low -> 4
        end
      end)

    repairable_anomalies =
      Enum.filter(sorted_anomalies, fn anomaly ->
        retry_count = get_retry_count(state.retry_tracker, anomaly.machine_id)
        retry_count < @max_retry_attempts
      end)

    anomalies_to_repair = Enum.take(repairable_anomalies, @max_concurrent_repairs)

    if length(anomalies_to_repair) < length(sorted_anomalies) do
      Logger.warning("Repair queue limited by concurrency",
        total_anomalies: length(sorted_anomalies),
        repairing_now: length(anomalies_to_repair),
        queued: length(sorted_anomalies) - length(anomalies_to_repair)
      )
    end

    tasks =
      Enum.map(anomalies_to_repair, fn anomaly ->
        Task.async(fn ->
          repair_anomaly_with_telemetry(anomaly)
        end)
      end)

    results = Task.await_many(tasks, 30_000)

    results
  end

  defp repair_anomaly_with_telemetry(anomaly) do
    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:orchestrator, :reconciler, :repair_attempted],
      %{count: 1},
      %{
        anomaly_type: anomaly.type,
        machine_id: anomaly.machine_id,
        severity: anomaly.severity
      }
    )

    result = RepairActions.execute_with_retry(anomaly, max_attempts: 3)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, outcome} ->
        :telemetry.execute(
          [:orchestrator, :reconciler, :repair_succeeded],
          %{duration_ms: duration_ms},
          %{
            anomaly_type: anomaly.type,
            machine_id: anomaly.machine_id,
            outcome: outcome
          }
        )

        Logger.info("Repair succeeded",
          machine_id: anomaly.machine_id,
          anomaly_type: anomaly.type,
          outcome: outcome,
          duration_ms: duration_ms
        )

      {:error, reason} ->
        :telemetry.execute(
          [:orchestrator, :reconciler, :repair_failed],
          %{count: 1},
          %{
            anomaly_type: anomaly.type,
            machine_id: anomaly.machine_id,
            reason: reason
          }
        )

        Logger.error("Repair failed after retries",
          machine_id: anomaly.machine_id,
          anomaly_type: anomaly.type,
          reason: inspect(reason),
          duration_ms: duration_ms
        )
    end

    result
  end

  defp repair_anomaly(anomaly, state) do
    result = repair_anomaly_with_telemetry(anomaly)

    new_retry_tracker =
      case result do
        {:ok, _outcome} ->
          Map.delete(state.retry_tracker, anomaly.machine_id)

        {:error, _reason} ->
          current_count = get_retry_count(state.retry_tracker, anomaly.machine_id)
          Map.put(state.retry_tracker, anomaly.machine_id, current_count + 1)
      end

    new_state = %{state | retry_tracker: new_retry_tracker}
    {result, new_state}
  end

  defp get_retry_count(retry_tracker, machine_id) do
    Map.get(retry_tracker, machine_id, 0)
  end

  defp schedule_next_cycle(state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    timer_ref = Process.send_after(self(), :reconciliation_cycle, state.config.interval_ms)

    %{state | timer_ref: timer_ref}
  end
end
