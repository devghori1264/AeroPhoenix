defmodule Orchestrator.Deployments.DeploymentController do
  use GenServer
  require Logger
  alias Orchestrator.Repo

  alias Orchestrator.Deployments.{
    Deployment,
    DeploymentRevision,
    DeploymentReplica,
    TrafficRoute,
    DeploymentEvent,
    CanaryAnalysisResult,
    DeploymentHook
  }

  alias Orchestrator.Machines.Machine
  import Ecto.Query
  @check_interval 5_000
  @health_check_interval 10_000
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec deploy(map()) :: {:ok, Deployment.t()} | {:error, term()}
  def deploy(attrs) do
    GenServer.call(__MODULE__, {:deploy, attrs}, 60_000)
  end

  @spec pause(binary()) :: :ok | {:error, term()}
  def pause(deployment_id) do
    GenServer.call(__MODULE__, {:pause, deployment_id})
  end

  @spec resume(binary()) :: :ok | {:error, term()}
  def resume(deployment_id) do
    GenServer.call(__MODULE__, {:resume, deployment_id})
  end

  @spec rollback(binary(), String.t()) :: {:ok, Deployment.t()} | {:error, term()}
  def rollback(deployment_id, reason \\ "Manual rollback") do
    GenServer.call(__MODULE__, {:rollback, deployment_id, reason}, 60_000)
  end

  @spec get_status(binary()) :: {:ok, map()} | {:error, term()}
  def get_status(deployment_id) do
    GenServer.call(__MODULE__, {:get_status, deployment_id})
  end

  @impl true
  def init(opts) do
    check_interval = Keyword.get(opts, :check_interval, @check_interval)
    schedule_check(check_interval)
    schedule_health_check(@health_check_interval)

    state = %{
      check_interval: check_interval,
      active_deployments: %{},
      stats: %{
        total_deployments: 0,
        successful: 0,
        failed: 0,
        rolled_back: 0,
        active: 0
      }
    }

    state = resume_active_deployments(state)
    Logger.info("DeploymentController started")
    {:ok, state}
  end

  @impl true
  def handle_call({:deploy, attrs}, _from, state) do
    case create_deployment(attrs) do
      {:ok, deployment} ->
        state =
          put_in(state.active_deployments[deployment.id], %{
            started_at: DateTime.utc_now(),
            last_check: nil
          })

        state = update_in(state.stats.total_deployments, &(&1 + 1))
        state = update_in(state.stats.active, &(&1 + 1))
        Task.start(fn -> execute_deployment(deployment) end)
        {:reply, {:ok, deployment}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:pause, deployment_id}, _from, state) do
    deployment = Repo.get(Deployment, deployment_id)

    if deployment && deployment.status == "in_progress" do
      Deployment.update(deployment, %{
        status: "paused",
        paused_at: DateTime.utc_now()
      })

      log_event(deployment_id, "deployment_paused", "info", "Deployment paused by user")
      {:reply, :ok, state}
    else
      {:reply, {:error, :invalid_state}, state}
    end
  end

  @impl true
  def handle_call({:resume, deployment_id}, _from, state) do
    deployment = Repo.get(Deployment, deployment_id)

    if deployment && deployment.status == "paused" do
      pause_duration =
        if deployment.paused_at do
          DateTime.diff(DateTime.utc_now(), deployment.paused_at, :millisecond)
        else
          0
        end

      Deployment.update(deployment, %{
        status: "in_progress",
        pause_duration_ms: (deployment.pause_duration_ms || 0) + pause_duration
      })

      log_event(deployment_id, "deployment_resumed", "info", "Deployment resumed")
      Task.start(fn -> execute_deployment(deployment) end)
      {:reply, :ok, state}
    else
      {:reply, {:error, :invalid_state}, state}
    end
  end

  @impl true
  def handle_call({:rollback, deployment_id, reason}, _from, state) do
    deployment = Repo.get(Deployment, deployment_id)

    if deployment do
      case perform_rollback(deployment, reason) do
        {:ok, deployment} ->
          state = update_in(state.stats.rolled_back, &(&1 + 1))
          {:reply, {:ok, deployment}, state}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_status, deployment_id}, _from, state) do
    deployment =
      Repo.get(Deployment, deployment_id)
      |> Repo.preload([:revisions, :replicas, :traffic_routes])

    if deployment do
      status = %{
        id: deployment.id,
        service: deployment.service,
        strategy: deployment.strategy,
        status: deployment.status,
        current_phase: deployment.current_phase,
        from_version: deployment.from_version,
        to_version: deployment.to_version,
        progress: %{
          target: deployment.target_replicas,
          ready: deployment.replicas_ready,
          updated: deployment.replicas_updated,
          available: deployment.replicas_available,
          unavailable: deployment.replicas_unavailable
        },
        duration_ms: calculate_duration(deployment),
        started_at: deployment.started_at,
        completed_at: deployment.completed_at
      }

      {:reply, {:ok, status}, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info(:check_deployments, state) do
    state = check_active_deployments(state)
    schedule_check(state.check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    perform_health_checks(state)
    schedule_health_check(@health_check_interval)
    {:noreply, state}
  end

  defp create_deployment(attrs) do
    current_version = get_current_version(attrs[:service])

    attrs =
      attrs
      |> Map.put(:from_version, current_version)
      |> Map.put(:status, "initializing")
      |> Map.put_new(:triggered_by, "system")

    Deployment.create(attrs)
  end

  defp execute_deployment(deployment) do
    Logger.info("Starting deployment #{deployment.id} for service #{deployment.service}")

    try do
      deployment = update_phase(deployment, "preparing")
      run_hooks(deployment, "pre_deployment")
      deployment = update_phase(deployment, "provisioning")
      {:ok, new_revision} = create_new_revision(deployment)

      deployment =
        case deployment.strategy do
          "rolling" -> execute_rolling_deployment(deployment, new_revision)
          "blue_green" -> execute_blue_green_deployment(deployment, new_revision)
          "canary" -> execute_canary_deployment(deployment, new_revision)
          "recreate" -> execute_recreate_deployment(deployment, new_revision)
          _ -> raise "Unknown strategy: #{deployment.strategy}"
        end

      Deployment.update(deployment, %{
        status: "succeeded",
        completed_at: DateTime.utc_now(),
        duration_ms: calculate_duration(deployment)
      })

      run_hooks(deployment, "post_deployment")

      log_event(
        deployment.id,
        "deployment_succeeded",
        "info",
        "Deployment completed successfully"
      )

      Logger.info("Deployment #{deployment.id} succeeded")
    rescue
      error ->
        Logger.error("Deployment #{deployment.id} failed: #{inspect(error)}")
        deployment = Repo.get(Deployment, deployment.id)

        Deployment.update(deployment, %{
          status: "failed",
          completed_at: DateTime.utc_now(),
          error_message: Exception.message(error),
          duration_ms: calculate_duration(deployment)
        })

        log_event(deployment.id, "deployment_failed", "error", Exception.message(error))

        if deployment.auto_rollback_enabled && deployment.rollback_on_failure do
          perform_rollback(deployment, "Automatic rollback due to deployment failure")
        end
    end
  end

  defp execute_rolling_deployment(deployment, new_revision) do
    deployment = update_phase(deployment, "deploying")
    deployment = Deployment.update_status(deployment, "in_progress")
    config = deployment.rolling_config || %{}
    max_surge = Map.get(config, "max_surge", 1)
    max_unavailable = Map.get(config, "max_unavailable", 0)
    target_replicas = deployment.target_replicas
    max_total = target_replicas + max_surge
    min_available = target_replicas - max_unavailable

    Logger.info(
      "Rolling update: target=#{target_replicas}, max_surge=#{max_surge}, max_unavailable=#{max_unavailable}"
    )

    old_replicas = DeploymentReplica.list_by_deployment(deployment.id)
    new_replicas_created = 0
    old_replicas_terminated = 0

    while new_replicas_created < target_replicas do
      deployment = Repo.get(Deployment, deployment.id)

      if deployment.status == "paused" do
        Logger.info("Deployment #{deployment.id} paused")
        Process.sleep(5000)
        :continue
      end

      current_total = length(DeploymentReplica.list_by_deployment(deployment.id))
      current_ready = deployment.replicas_ready || 0

      if current_total < max_total && new_replicas_created < target_replicas do
        {:ok, replica} = create_replica(deployment, new_revision, new_replicas_created)
        new_replicas_created = new_replicas_created + 1

        log_event(
          deployment.id,
          "replica_created",
          "info",
          "Created new replica: #{replica.replica_name}"
        )

        wait_for_replica_ready(replica, deployment)
      end

      if current_ready >= min_available && old_replicas_terminated < length(old_replicas) do
        old_replica = Enum.at(old_replicas, old_replicas_terminated)

        if old_replica do
          terminate_replica(old_replica)
          old_replicas_terminated = old_replicas_terminated + 1

          log_event(
            deployment.id,
            "replica_terminated",
            "info",
            "Terminated old replica: #{old_replica.replica_name}"
          )
        end
      end

      Process.sleep(2000)
    end

    deployment = update_phase(deployment, "completing")
    wait_for_all_ready(deployment, target_replicas)
    deployment
  end

  defp execute_blue_green_deployment(deployment, new_revision) do
    deployment = update_phase(deployment, "deploying")
    deployment = Deployment.update_status(deployment, "in_progress")
    config = deployment.blue_green_config || %{}
    Logger.info("Blue/Green: Creating #{deployment.target_replicas} green replicas")

    green_replicas =
      Enum.map(1..deployment.target_replicas, fn i ->
        {:ok, replica} = create_replica(deployment, new_revision, i - 1)
        replica
      end)

    deployment = update_phase(deployment, "health_checking")
    wait_for_all_ready(deployment, deployment.target_replicas)
    deployment = update_phase(deployment, "traffic_shifting")

    {:ok, _route} =
      TrafficRoute.create(%{
        deployment_id: deployment.id,
        name: "blue_green_switch",
        split_type: "percentage",
        enabled: true,
        old_version_weight: 0,
        new_version_weight: 100
      })

    log_event(
      deployment.id,
      "traffic_switched",
      "info",
      "Traffic switched to green (new version)"
    )

    deployment = update_phase(deployment, "monitoring")
    monitor_duration = Map.get(config, "monitor_duration_seconds", 300)
    Logger.info("Blue/Green: Monitoring green for #{monitor_duration} seconds")
    Process.sleep(monitor_duration * 1000)

    old_replicas =
      DeploymentReplica.list_by_deployment(deployment.id)
      |> Enum.reject(&(&1.revision_id == new_revision.id))

    deployment = update_phase(deployment, "cleaning_up")

    Enum.each(old_replicas, fn replica ->
      terminate_replica(replica)

      log_event(
        deployment.id,
        "replica_terminated",
        "info",
        "Terminated blue replica: #{replica.replica_name}"
      )
    end)

    deployment
  end

  defp execute_canary_deployment(deployment, new_revision) do
    deployment = update_phase(deployment, "deploying")
    deployment = Deployment.update_status(deployment, "in_progress")
    config = deployment.canary_config || %{}
    initial_traffic = Map.get(config, "initial_traffic_percent", 10)
    increment = Map.get(config, "increment_percent", 10)
    interval = Map.get(config, "interval_seconds", 300)
    analysis_interval = Map.get(config, "analysis_interval_seconds", 60)
    canary_count = max(1, div(deployment.target_replicas * initial_traffic, 100))
    Logger.info("Canary: Starting with #{canary_count} replicas (#{initial_traffic}% traffic)")

    canary_replicas =
      Enum.map(1..canary_count, fn i ->
        {:ok, replica} = create_replica(deployment, new_revision, i - 1)
        replica
      end)

    wait_for_all_ready(deployment, canary_count)

    {:ok, route} =
      TrafficRoute.create(%{
        deployment_id: deployment.id,
        name: "canary_route",
        split_type: "percentage",
        enabled: true,
        old_version_weight: 100 - initial_traffic,
        new_version_weight: initial_traffic
      })

    log_event(
      deployment.id,
      "canary_started",
      "info",
      "Canary deployed with #{initial_traffic}% traffic"
    )

    current_traffic = initial_traffic
    analysis_run = 0

    while current_traffic < 100 do
      deployment = Repo.get(Deployment, deployment.id)

      if deployment.status == "paused" do
        Process.sleep(5000)
        next
      end

      deployment = update_phase(deployment, "monitoring")
      Process.sleep(analysis_interval * 1000)
      deployment = update_phase(deployment, "health_checking")
      analysis_run = analysis_run + 1

      analysis_result =
        perform_canary_analysis(deployment, new_revision, analysis_run, current_traffic)

      if analysis_result.passed do
        Logger.info("Canary analysis passed (run #{analysis_run})")
        current_traffic = min(100, current_traffic + increment)

        TrafficRoute.update(route, %{
          old_version_weight: 100 - current_traffic,
          new_version_weight: current_traffic
        })

        log_event(
          deployment.id,
          "canary_promoted",
          "info",
          "Canary traffic increased to #{current_traffic}%"
        )

        if current_traffic < 100 do
          new_canary_count =
            max(canary_count, div(deployment.target_replicas * current_traffic, 100))

          if new_canary_count > canary_count do
            additional = new_canary_count - canary_count

            Enum.each(1..additional, fn i ->
              create_replica(deployment, new_revision, canary_count + i - 1)
            end)

            canary_count = new_canary_count
          end
        end
      else
        Logger.error(
          "Canary analysis failed (run #{analysis_run}): #{inspect(analysis_result.failure_reasons)}"
        )

        log_event(
          deployment.id,
          "canary_failed",
          "error",
          "Canary analysis failed: #{Enum.join(analysis_result.failure_reasons, ", ")}"
        )

        perform_rollback(deployment, "Canary analysis failed")
        raise "Canary analysis failed"
      end

      if current_traffic < 100 do
        Process.sleep(interval * 1000)
      end
    end

    deployment = update_phase(deployment, "cleaning_up")

    old_replicas =
      DeploymentReplica.list_by_deployment(deployment.id)
      |> Enum.reject(&(&1.revision_id == new_revision.id))

    Enum.each(old_replicas, fn replica ->
      terminate_replica(replica)
    end)

    deployment
  end

  defp execute_recreate_deployment(deployment, new_revision) do
    deployment = update_phase(deployment, "deploying")
    deployment = Deployment.update_status(deployment, "in_progress")
    old_replicas = DeploymentReplica.list_by_deployment(deployment.id)

    Enum.each(old_replicas, fn replica ->
      terminate_replica(replica)

      log_event(
        deployment.id,
        "replica_terminated",
        "info",
        "Terminated replica: #{replica.replica_name}"
      )
    end)

    Enum.each(1..deployment.target_replicas, fn i ->
      {:ok, replica} = create_replica(deployment, new_revision, i - 1)

      log_event(
        deployment.id,
        "replica_created",
        "info",
        "Created replica: #{replica.replica_name}"
      )
    end)

    wait_for_all_ready(deployment, deployment.target_replicas)
    deployment
  end

  defp create_new_revision(deployment) do
    latest_revision = DeploymentRevision.get_latest(deployment.id)
    revision_number = if latest_revision, do: latest_revision.revision_number + 1, else: 1

    DeploymentRevision.create(%{
      deployment_id: deployment.id,
      revision_number: revision_number,
      version: deployment.to_version,
      artifact_url: deployment.artifact_url,
      artifact_hash: deployment.artifact_hash,
      replicas: deployment.target_replicas,
      status: "deploying",
      deployed_at: DateTime.utc_now(),
      is_active: true
    })
  end

  defp create_replica(deployment, revision, index) do
    replica_name = "#{deployment.service}-#{revision.version}-#{index}"

    DeploymentReplica.create(%{
      deployment_id: deployment.id,
      revision_id: revision.id,
      replica_name: replica_name,
      status: "pending",
      health_status: "unknown",
      ready: false,
      created_at_time: DateTime.utc_now()
    })
  end

  defp wait_for_replica_ready(replica, deployment, timeout \\ 300_000) do
    start_time = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn ->
      replica = Repo.get(DeploymentReplica, replica.id)

      if replica.ready do
        :ok
      else
        elapsed = System.monotonic_time(:millisecond) - start_time

        if elapsed > timeout do
          raise "Replica #{replica.replica_name} failed to become ready within #{timeout}ms"
        end

        Process.sleep(2000)
        :continue
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end

  defp wait_for_all_ready(deployment, target_count, timeout \\ 600_000) do
    start_time = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn ->
      deployment = Repo.get(Deployment, deployment.id)

      if deployment.replicas_ready >= target_count do
        :ok
      else
        elapsed = System.monotonic_time(:millisecond) - start_time

        if elapsed > timeout do
          raise "Deployment failed to reach #{target_count} ready replicas within #{timeout}ms"
        end

        Process.sleep(5000)
        :continue
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end

  defp terminate_replica(replica) do
    DeploymentReplica.update(replica, %{
      status: "terminated",
      terminated_at: DateTime.utc_now(),
      receiving_traffic: false
    })

    if replica.machine_id do
      case Machine.get(replica.machine_id) do
        {:ok, machine} -> Machine.destroy(machine)
        _ -> :ok
      end
    end
  end

  defp perform_canary_analysis(deployment, canary_revision, analysis_run, traffic_percent) do
    baseline_metrics = get_revision_metrics(deployment, :baseline)
    canary_metrics = get_revision_metrics(deployment, canary_revision.id)
    config = deployment.canary_config || %{}
    success_rate_threshold = Map.get(config, "success_rate_threshold", 99.5)
    latency_threshold_ms = Map.get(config, "latency_p95_threshold_ms", 500)
    error_rate_threshold = Map.get(config, "error_rate_threshold", 0.5)
    passed = true
    failure_reasons = []

    if canary_metrics.success_rate < success_rate_threshold do
      passed = false

      failure_reasons =
        failure_reasons ++
          [
            "Success rate #{canary_metrics.success_rate}% below threshold #{success_rate_threshold}%"
          ]
    end

    if canary_metrics.latency_p95_ms > latency_threshold_ms do
      passed = false

      failure_reasons =
        failure_reasons ++
          [
            "P95 latency #{canary_metrics.latency_p95_ms}ms above threshold #{latency_threshold_ms}ms"
          ]
    end

    if canary_metrics.error_rate > error_rate_threshold do
      passed = false

      failure_reasons =
        failure_reasons ++
          ["Error rate #{canary_metrics.error_rate}% above threshold #{error_rate_threshold}%"]
    end

    score =
      canary_metrics.success_rate / success_rate_threshold * 40 +
        (latency_threshold_ms - canary_metrics.latency_p95_ms) / latency_threshold_ms * 30 +
        (error_rate_threshold - canary_metrics.error_rate) / error_rate_threshold * 30

    recommendation =
      cond do
        score >= 80 -> "promote"
        score >= 60 -> "continue"
        true -> "abort"
      end

    {:ok, result} =
      CanaryAnalysisResult.create(%{
        deployment_id: deployment.id,
        analysis_run: analysis_run,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        baseline_version: deployment.from_version,
        canary_version: deployment.to_version,
        traffic_percentage: traffic_percent,
        success_rate_baseline: baseline_metrics.success_rate,
        success_rate_canary: canary_metrics.success_rate,
        latency_p95_baseline_ms: baseline_metrics.latency_p95_ms,
        latency_p95_canary_ms: canary_metrics.latency_p95_ms,
        error_rate_baseline: baseline_metrics.error_rate,
        error_rate_canary: canary_metrics.error_rate,
        passed: passed,
        score: score,
        recommendation: recommendation,
        failure_reasons: failure_reasons,
        success_rate_threshold: success_rate_threshold,
        latency_threshold_ms: latency_threshold_ms,
        error_rate_threshold: error_rate_threshold
      })

    result
  end

  defp get_revision_metrics(_deployment, :baseline) do
    %{
      success_rate: 99.9,
      latency_p95_ms: 250,
      error_rate: 0.1
    }
  end

  defp get_revision_metrics(_deployment, _revision_id) do
    %{
      success_rate: 99.8,
      latency_p95_ms: 280,
      error_rate: 0.2
    }
  end

  defp perform_rollback(deployment, reason) do
    Logger.info("Rolling back deployment #{deployment.id}: #{reason}")
    previous_revision = DeploymentRevision.get_previous_active(deployment.id)

    if previous_revision do
      {:ok, rollback_deployment} =
        Deployment.create(%{
          service: deployment.service,
          strategy: "recreate",
          from_version: deployment.to_version,
          to_version: previous_revision.version,
          rollback_to_version: previous_revision.version,
          rollback_reason: reason,
          target_replicas: deployment.target_replicas,
          triggered_by: "rollback_automation"
        })

      run_hooks(rollback_deployment, "pre_rollback")
      current_replicas = DeploymentReplica.list_by_deployment(deployment.id)
      Enum.each(current_replicas, &terminate_replica/1)

      Enum.each(1..deployment.target_replicas, fn i ->
        create_replica(rollback_deployment, previous_revision, i - 1)
      end)

      Deployment.update(deployment, %{
        status: "rolled_back",
        rollback_reason: reason,
        completed_at: DateTime.utc_now()
      })

      run_hooks(rollback_deployment, "post_rollback")
      log_event(deployment.id, "deployment_rolled_back", "warning", reason)
      {:ok, deployment}
    else
      {:error, :no_previous_revision}
    end
  end

  defp run_hooks(deployment, hook_type) do
    hooks =
      DeploymentHook.list_by_type(deployment.id, hook_type)
      |> Enum.sort_by(& &1.execution_order)

    Enum.each(hooks, fn hook ->
      execute_hook(hook)
    end)
  end

  defp execute_hook(hook) do
    Logger.info("Executing hook: #{hook.hook_name}")

    DeploymentHook.update(hook, %{
      status: "running",
      started_at: DateTime.utc_now()
    })

    Process.sleep(1000)

    DeploymentHook.update(hook, %{
      status: "succeeded",
      completed_at: DateTime.utc_now(),
      exit_code: 0
    })
  end

  defp update_phase(deployment, phase) do
    {:ok, deployment} = Deployment.update(deployment, %{current_phase: phase})
    log_event(deployment.id, "phase_change", "info", "Entered phase: #{phase}")
    deployment
  end

  defp log_event(deployment_id, event_type, severity, message) do
    DeploymentEvent.create(%{
      deployment_id: deployment_id,
      event_type: event_type,
      event_severity: severity,
      message: message,
      occurred_at: DateTime.utc_now()
    })
  end

  defp get_current_version(service) do
    "v1.0.0"
  end

  defp calculate_duration(deployment) do
    if deployment.started_at && deployment.completed_at do
      DateTime.diff(deployment.completed_at, deployment.started_at, :millisecond)
    else
      nil
    end
  end

  defp resume_active_deployments(state) do
    active = Deployment.list_active()

    Enum.each(active, fn deployment ->
      Logger.info("Resuming deployment #{deployment.id}")
      Task.start(fn -> execute_deployment(deployment) end)
    end)

    update_in(state.stats.active, &(&1 + length(active)))
  end

  defp check_active_deployments(state) do
    state
  end

  defp perform_health_checks(_state) do
    active_replicas = DeploymentReplica.list_active()

    Enum.each(active_replicas, fn replica ->
      health_status = check_replica_health(replica)

      DeploymentReplica.update(replica, %{
        health_status: health_status,
        last_health_check_at: DateTime.utc_now(),
        ready: health_status in ["healthy", "degraded"]
      })
    end)
  end

  defp check_replica_health(_replica) do
    if :rand.uniform() > 0.1, do: "healthy", else: "degraded"
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_deployments, interval)
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end
end
