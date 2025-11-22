defmodule Orchestrator.LiveMigration.Cutover do
  require Logger
  alias Orchestrator.FlydClient

  @type cutover_result :: %{
          success: boolean(),
          new_endpoint: String.t(),
          cutover_duration_ms: non_neg_integer(),
          connections_migrated: non_neg_integer(),
          connections_dropped: non_neg_integer(),
          requests_replayed: non_neg_integer()
        }
  @default_drain_timeout_ms 30_000
  @health_check_retries 5
  @health_check_interval_ms 1000
  @spec perform_cutover(String.t(), String.t(), String.t(), map()) ::
          {:ok, cutover_result()} | {:error, term()}
  def perform_cutover(machine_id, source_region, target_region, opts \\ %{}) do
    Logger.info("Starting network cutover",
      machine_id: machine_id,
      source: source_region,
      target: target_region,
      preserve_ip: Map.get(opts, :preserve_ip, false)
    )

    cutover_start = System.monotonic_time(:millisecond)

    with :ok <- validate_target_readiness(machine_id, target_region, opts),
         {:ok, traffic_buffer} <- maybe_start_traffic_replay(machine_id, source_region, opts),
         :ok <- drain_source_connections(machine_id, source_region, opts),
         {:ok, new_endpoint} <- switch_network(machine_id, source_region, target_region, opts),
         :ok <- maybe_replay_traffic(traffic_buffer, new_endpoint, opts),
         {:ok, migration_stats} <- finalize_cutover(machine_id, source_region, target_region) do
      cutover_duration = System.monotonic_time(:millisecond) - cutover_start

      result = %{
        success: true,
        new_endpoint: new_endpoint,
        cutover_duration_ms: cutover_duration,
        connections_migrated: migration_stats[:migrated] || 0,
        connections_dropped: migration_stats[:dropped] || 0,
        requests_replayed: migration_stats[:replayed] || 0
      }

      Logger.info("Cutover completed successfully",
        machine_id: machine_id,
        new_endpoint: new_endpoint,
        duration_ms: cutover_duration,
        connections_migrated: result.connections_migrated
      )

      :telemetry.execute(
        [:orchestrator, :cutover, :completed],
        %{
          duration_ms: cutover_duration,
          connections_migrated: result.connections_migrated,
          connections_dropped: result.connections_dropped
        },
        %{machine_id: machine_id}
      )

      {:ok, result}
    else
      {:error, reason} = error ->
        cutover_duration = System.monotonic_time(:millisecond) - cutover_start

        Logger.error("Cutover failed",
          machine_id: machine_id,
          reason: reason,
          duration_ms: cutover_duration
        )

        if Map.get(opts, :rollback_on_failure, true) do
          Logger.warning("Attempting cutover rollback", machine_id: machine_id)
          rollback_cutover(machine_id, source_region, target_region)
        end

        :telemetry.execute(
          [:orchestrator, :cutover, :failed],
          %{duration_ms: cutover_duration},
          %{machine_id: machine_id, reason: reason}
        )

        error
    end
  end

  defp validate_target_readiness(machine_id, target_region, opts) do
    Logger.debug("Validating target readiness", machine_id: machine_id)
    retries = Map.get(opts, :health_check_retries, @health_check_retries)
    interval = Map.get(opts, :health_check_interval_ms, @health_check_interval_ms)
    check_health_with_retries(machine_id, target_region, retries, interval)
  end

  defp check_health_with_retries(machine_id, region, retries, interval) when retries > 0 do
    case FlydClient.get_machine_health(region, machine_id) do
      {:ok, %{status: "healthy"}} ->
        Logger.debug("Target health check passed", machine_id: machine_id)
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("Target not healthy, retrying",
          machine_id: machine_id,
          status: status,
          retries_left: retries - 1
        )

        Process.sleep(interval)
        check_health_with_retries(machine_id, region, retries - 1, interval)

      {:error, :not_implemented} ->
        Logger.debug("Health check not implemented, assuming healthy")
        :ok

      error ->
        Logger.error("Health check failed", machine_id: machine_id, error: inspect(error))
        error
    end
  end

  defp check_health_with_retries(machine_id, _region, 0, _interval) do
    {:error, {:health_check_failed, "Target not ready after max retries", machine_id}}
  end

  defp maybe_start_traffic_replay(machine_id, source_region, opts) do
    if Map.get(opts, :traffic_replay, false) do
      Logger.info("Starting traffic replay buffer", machine_id: machine_id)

      case FlydClient.start_traffic_capture(source_region, machine_id) do
        {:ok, buffer_id} ->
          {:ok, buffer_id}

        {:error, :not_implemented} ->
          Logger.debug("Traffic replay not implemented")
          {:ok, nil}

        error ->
          Logger.warning("Failed to start traffic replay", error: inspect(error))
          {:ok, nil}
      end
    else
      {:ok, nil}
    end
  end

  defp drain_source_connections(machine_id, source_region, opts) do
    timeout_ms = Map.get(opts, :drain_timeout_ms, @default_drain_timeout_ms)

    Logger.info("Draining source connections",
      machine_id: machine_id,
      timeout_ms: timeout_ms
    )

    drain_start = System.monotonic_time(:millisecond)

    case FlydClient.drain_connections(source_region, machine_id, timeout_ms) do
      :ok ->
        duration = System.monotonic_time(:millisecond) - drain_start

        Logger.info("Connection drain completed",
          machine_id: machine_id,
          duration_ms: duration
        )

        :ok

      {:error, :timeout} ->
        Logger.warning("Connection drain timed out, proceeding with cutover",
          machine_id: machine_id
        )

        :ok

      {:error, :not_implemented} ->
        Logger.debug("Connection draining not implemented")
        :ok

      error ->
        Logger.error("Connection drain failed", error: inspect(error))
        error
    end
  end

  defp switch_network(machine_id, source_region, target_region, opts) do
    Logger.info("Switching network traffic", machine_id: machine_id)

    if Map.get(opts, :preserve_ip, false) do
      switch_with_ip_preservation(machine_id, source_region, target_region, opts)
    else
      switch_with_dns(machine_id, source_region, target_region, opts)
    end
  end

  defp switch_with_ip_preservation(machine_id, source_region, target_region, opts) do
    Logger.info("Performing IP-preserving cutover", machine_id: machine_id)

    with {:ok, ip_address} <- FlydClient.release_ip(source_region, machine_id),
         :ok <- FlydClient.assign_ip(target_region, machine_id, ip_address) do
      Logger.info("IP preserved during cutover",
        machine_id: machine_id,
        ip: ip_address
      )

      endpoint = "#{ip_address}:8080"
      {:ok, endpoint}
    else
      {:error, :not_implemented} ->
        Logger.warning("IP preservation not implemented, falling back to DNS")
        switch_with_dns(machine_id, source_region, target_region, opts)

      error ->
        Logger.error("IP preservation failed", error: inspect(error))
        error
    end
  end

  defp switch_with_dns(machine_id, _source_region, target_region, opts) do
    Logger.info("Performing DNS cutover", machine_id: machine_id)
    dns_ttl = Map.get(opts, :dns_ttl, 60)

    case FlydClient.update_dns_record(machine_id, target_region, dns_ttl) do
      {:ok, new_endpoint} ->
        Logger.info("DNS updated",
          machine_id: machine_id,
          new_endpoint: new_endpoint,
          ttl: dns_ttl
        )

        {:ok, new_endpoint}

      {:error, :not_implemented} ->
        Logger.debug("DNS update not implemented, using constructed endpoint")
        endpoint = "#{machine_id}.#{target_region}.example.com:8080"
        {:ok, endpoint}

      error ->
        error
    end
  end

  defp maybe_replay_traffic(nil, _endpoint, _opts), do: :ok

  defp maybe_replay_traffic(buffer_id, new_endpoint, opts) do
    if Map.get(opts, :traffic_replay, false) do
      Logger.info("Replaying captured traffic", buffer_id: buffer_id)

      case FlydClient.replay_captured_traffic(buffer_id, new_endpoint) do
        {:ok, stats} ->
          Logger.info("Traffic replay completed",
            requests_replayed: stats[:count] || 0,
            success_rate: stats[:success_rate] || 1.0
          )

          :ok

        {:error, :not_implemented} ->
          Logger.debug("Traffic replay not implemented")
          :ok

        error ->
          Logger.warning("Traffic replay failed", error: inspect(error))
          :ok
      end
    else
      :ok
    end
  end

  defp finalize_cutover(machine_id, source_region, target_region) do
    Logger.debug("Finalizing cutover", machine_id: machine_id)

    case FlydClient.get_connection_stats(source_region, machine_id) do
      {:ok, source_stats} ->
        case FlydClient.get_connection_stats(target_region, machine_id) do
          {:ok, target_stats} ->
            stats = %{
              migrated: target_stats[:active_connections] || 0,
              dropped: source_stats[:dropped_connections] || 0,
              replayed: target_stats[:replayed_requests] || 0
            }

            {:ok, stats}

          {:error, :not_implemented} ->
            {:ok, %{migrated: 0, dropped: 0, replayed: 0}}

          error ->
            Logger.warning("Could not get target stats", error: inspect(error))
            {:ok, %{migrated: 0, dropped: 0, replayed: 0}}
        end

      {:error, :not_implemented} ->
        {:ok, %{migrated: 0, dropped: 0, replayed: 0}}

      error ->
        Logger.warning("Could not get source stats", error: inspect(error))
        {:ok, %{migrated: 0, dropped: 0, replayed: 0}}
    end
  end

  defp rollback_cutover(machine_id, source_region, target_region) do
    Logger.warning("Rolling back cutover",
      machine_id: machine_id,
      from: target_region,
      to: source_region
    )

    rollback_start = System.monotonic_time(:millisecond)

    case switch_network(machine_id, target_region, source_region, %{}) do
      {:ok, source_endpoint} ->
        duration = System.monotonic_time(:millisecond) - rollback_start

        Logger.info("Cutover rollback completed",
          machine_id: machine_id,
          restored_endpoint: source_endpoint,
          duration_ms: duration
        )

        :telemetry.execute(
          [:orchestrator, :cutover, :rollback, :completed],
          %{duration_ms: duration},
          %{machine_id: machine_id}
        )

        {:ok, source_endpoint}

      error ->
        Logger.error("Cutover rollback failed",
          machine_id: machine_id,
          error: inspect(error)
        )

        error
    end
  end
end
