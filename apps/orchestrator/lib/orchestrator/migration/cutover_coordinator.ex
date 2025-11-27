defmodule Orchestrator.Migration.CutoverCoordinator do
  use GenServer
  require Logger

  def init(_), do: {:ok, %{}}

  alias Orchestrator.Migration.{WriteBlocker, RoutingUpdater, StateTransfer}
  alias Orchestrator.MachineActor

  @type machine_id :: String.t()
  @type cutover_result :: :ok | {:error, term()}

  @health_check_timeout_ms 10_000
  @drain_timeout_ms 5_000

  @spec execute_cutover(keyword()) :: {:ok, map()} | {:error, term()}
  def execute_cutover(opts) do
    source_machine = Keyword.fetch!(opts, :source_machine)
    dest_machine = Keyword.fetch!(opts, :dest_machine)
    migration_id = Keyword.fetch!(opts, :migration_id)

    drain_timeout = Keyword.get(opts, :drain_timeout_ms, @drain_timeout_ms)
    health_timeout = Keyword.get(opts, :health_check_timeout_ms, @health_check_timeout_ms)
    verify_checksums = Keyword.get(opts, :verify_checksums, true)

    Logger.info("Starting atomic cutover",
      migration_id: migration_id,
      source: source_machine,
      dest: dest_machine
    )

    cutover_start = :os.system_time(:microsecond)

    result =
      with {:ok, step1_duration} <-
             step1_block_writes(source_machine, drain_timeout, cutover_start),
           {:ok, step2_stats} <-
             step2_tail_sync(
               source_machine,
               dest_machine,
               migration_id,
               verify_checksums,
               cutover_start
             ),
           {:ok, step3_duration} <-
             step3_start_destination(dest_machine, health_timeout, cutover_start),
           {:ok, step4_duration} <-
             step4_update_routing(source_machine, dest_machine, migration_id, cutover_start) do
        cutover_end = :os.system_time(:microsecond)
        total_duration_us = cutover_end - cutover_start

        stats = %{
          total_duration_ms: total_duration_us / 1000,
          downtime_ms: total_duration_us / 1000,
          step1_block_writes_ms: step1_duration / 1000,
          step2_tail_sync_ms: step2_stats.duration_us / 1000,
          step2_tail_sync_bytes: step2_stats.bytes_transferred,
          step3_start_dest_ms: step3_duration / 1000,
          step4_routing_ms: step4_duration / 1000,
          migration_id: migration_id,
          source: source_machine,
          dest: dest_machine
        }

        log_cutover_success(stats, cutover_start)

        :telemetry.execute(
          [:orchestrator, :migration, :cutover_complete],
          stats,
          %{migration_id: migration_id}
        )

        {:ok, stats}
      else
        {:error, step, reason} ->
          rollback_cutover(
            source_machine,
            dest_machine,
            migration_id,
            step,
            reason,
            cutover_start
          )

          {:error, {step, reason}}
      end

    result
  end

  defp step1_block_writes(source_machine, drain_timeout, cutover_start) do
    step_start = :os.system_time(:microsecond)

    log_cutover_step(1, "Blocking writes on source", source_machine, cutover_start)

    case WriteBlocker.block_writes(source_machine, drain_timeout: drain_timeout) do
      {:ok, drain_stats} ->
        step_duration = :os.system_time(:microsecond) - step_start

        log_cutover_step_complete(1, step_duration, cutover_start,
          in_flight_drained: drain_stats.requests_drained,
          drain_duration_ms: drain_stats.duration_ms
        )

        {:ok, step_duration}

      {:error, :drain_timeout} ->
        log_cutover_error(1, "In-flight request drain timeout", cutover_start)
        {:error, :step1_block_writes, :drain_timeout}

      {:error, reason} ->
        log_cutover_error(1, "Failed to block writes: #{inspect(reason)}", cutover_start)
        {:error, :step1_block_writes, reason}
    end
  end

  defp step2_tail_sync(
         source_machine,
         dest_machine,
         migration_id,
         verify_checksums,
         cutover_start
       ) do
    step_start = :os.system_time(:microsecond)

    log_cutover_step(2, "Syncing tail (final delta)", dest_machine, cutover_start)

    case StateTransfer.sync_dirty_pages(source_machine, dest_machine, migration_id) do
      {:ok, sync_stats} ->
        if verify_checksums do
          case verify_data_checksums(source_machine, dest_machine, cutover_start) do
            :ok ->
              step_duration = :os.system_time(:microsecond) - step_start

              log_cutover_step_complete(2, step_duration, cutover_start,
                bytes_synced: sync_stats[:bytes_transferred],
                pages_synced: sync_stats.pages_transferred,
                checksum_verified: true
              )

              {:ok,
               %{duration_us: step_duration, bytes_transferred: sync_stats.bytes_transferred}}

            {:error, :checksum_mismatch, details} ->
              log_cutover_error(2, "Checksum mismatch: #{inspect(details)}", cutover_start)
              {:error, :step2_tail_sync, {:checksum_mismatch, details}}
          end
        else
          step_duration = :os.system_time(:microsecond) - step_start

          log_cutover_step_complete(2, step_duration, cutover_start,
            bytes_synced: sync_stats[:bytes_transferred],
            checksum_verified: false
          )

          {:ok, %{duration_us: step_duration, bytes_transferred: sync_stats.bytes_transferred}}
        end
    end
  end

  defp step3_start_destination(dest_machine, health_timeout, cutover_start) do
    step_start = :os.system_time(:microsecond)

    log_cutover_step(3, "Starting destination and verifying health", dest_machine, cutover_start)

    case MachineActor.start(id: dest_machine, region: "destination") do
      {:ok, _pid} ->
        case wait_for_health(dest_machine, health_timeout, cutover_start) do
          :ok ->
            step_duration = :os.system_time(:microsecond) - step_start

            log_cutover_step_complete(3, step_duration, cutover_start, health_check_passed: true)

            {:ok, step_duration}

          {:error, :timeout} ->
            log_cutover_error(3, "Health check timeout", cutover_start)
            {:error, :health_check_timeout}

          {:error, reason} ->
            log_cutover_error(3, "Health check failed: #{inspect(reason)}", cutover_start)
            {:error, :step3_start_destination, reason}
        end

      {:error, reason} ->
        log_cutover_error(3, "Failed to start destination: #{inspect(reason)}", cutover_start)
        {:error, :step3_start_destination, reason}
    end
  end

  defp step4_update_routing(source_machine, dest_machine, migration_id, cutover_start) do
    step_start = :os.system_time(:microsecond)

    log_cutover_step(4, "Updating routing atomically", dest_machine, cutover_start)

    case RoutingUpdater.update_route(source_machine, dest_machine, migration_id) do
      :ok ->
        step_duration = :os.system_time(:microsecond) - step_start

        log_cutover_step_complete(4, step_duration, cutover_start, routing_updated: true)

        {:ok, step_duration}
    end
  end

  defp verify_data_checksums(source_machine, dest_machine, cutover_start) do
    log_microsecond("Computing checksums", cutover_start)

    source_checksum = compute_machine_checksum(source_machine)
    dest_checksum = compute_machine_checksum(dest_machine)

    if source_checksum == dest_checksum do
      log_microsecond("Checksums match (#{source_checksum})", cutover_start)
      :ok
    else
      {:error, :checksum_mismatch,
       %{
         source: source_checksum,
         dest: dest_checksum
       }}
    end
  end

  defp compute_machine_checksum(_machine_id) do
    :crypto.hash(:sha256, :crypto.strong_rand_bytes(32))
    |> Base.encode16(case: :lower)
    |> String.slice(0..7)
  end

  defp wait_for_health(dest_machine, _timeout_ms, cutover_start) do
    log_microsecond("Waiting for health check", cutover_start)

    Process.sleep(30)

    case MachineActor.health_check(dest_machine) do
      {:ok, :healthy} ->
        log_microsecond("Health check passed", cutover_start)
        :ok

      {:ok, :degraded} ->
        Logger.warning("Machine health is degraded but acceptable")
        :ok

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :health_check_exception}
  end

  defp rollback_cutover(
         source_machine,
         dest_machine,
         migration_id,
         failed_step,
         reason,
         cutover_start
       ) do
    log_microsecond(
      "ROLLBACK: Cutover failed at #{failed_step}, reason: #{inspect(reason)}",
      cutover_start
    )

    Logger.error("Cutover failed, rolling back",
      migration_id: migration_id,
      failed_step: failed_step,
      reason: reason,
      source: source_machine,
      dest: dest_machine
    )

    case WriteBlocker.unblock_writes(source_machine) do
      :ok ->
        log_microsecond("Source writes resumed (rollback complete)", cutover_start)
    end

    if failed_step in [:step3_start_destination, :step4_update_routing] do
      MachineActor.stop(dest_machine)
      log_microsecond("Destination stopped (rollback)", cutover_start)
    end

    :telemetry.execute(
      [:orchestrator, :migration, :cutover_failed],
      %{failed_step: failed_step},
      %{migration_id: migration_id, reason: reason}
    )

    :ok
  end

  defp log_cutover_step(step_number, description, machine_id, cutover_start) do
    elapsed_us = :os.system_time(:microsecond) - cutover_start

    Logger.info("[T+#{format_microseconds(elapsed_us)}] Step #{step_number}: #{description}",
      machine_id: machine_id,
      step: step_number
    )
  end

  defp log_cutover_step_complete(step_number, step_duration_us, cutover_start, extra_info) do
    elapsed_us = :os.system_time(:microsecond) - cutover_start

    Logger.info(
      "[T+#{format_microseconds(elapsed_us)}] Step #{step_number} complete (#{format_microseconds(step_duration_us)})",
      [step: step_number, duration_us: step_duration_us] ++ extra_info
    )
  end

  defp log_cutover_error(step_number, message, cutover_start) do
    elapsed_us = :os.system_time(:microsecond) - cutover_start

    Logger.error("[T+#{format_microseconds(elapsed_us)}] Step #{step_number} FAILED: #{message}",
      step: step_number
    )
  end

  defp log_cutover_success(stats, cutover_start) do
    elapsed_us = :os.system_time(:microsecond) - cutover_start

    Logger.info("[T+#{format_microseconds(elapsed_us)}] Cutover COMPLETE",
      total_duration_ms: Float.round(stats.total_duration_ms, 3),
      downtime_ms: Float.round(stats.downtime_ms, 3),
      tail_sync_mb: Float.round(stats.step2_tail_sync_bytes / 1_048_576, 3),
      migration_id: stats.migration_id
    )
  end

  defp log_microsecond(message, cutover_start) do
    elapsed_us = :os.system_time(:microsecond) - cutover_start
    Logger.debug("[T+#{format_microseconds(elapsed_us)}] #{message}")
  end

  defp format_microseconds(microseconds) do
    ms = microseconds / 1000
    "#{Float.round(ms, 3)}ms"
  end
end
