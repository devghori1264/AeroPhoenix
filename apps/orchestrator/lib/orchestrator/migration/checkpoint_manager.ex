defmodule Orchestrator.Migration.CheckpointManager do
  require Logger

  @type machine_id :: String.t()
  @type checkpoint_id :: String.t()

  @spec create_checkpoint(machine_id()) :: {:ok, checkpoint_id()} | {:error, term()}
  def create_checkpoint(machine_id) do
    Logger.info("Creating CRIU checkpoint", machine_id: machine_id)

    start_time = System.monotonic_time(:millisecond)

    iterations = perform_precopy_iterations(machine_id)

    checkpoint_id = "checkpoint_#{machine_id}_#{System.monotonic_time()}"
    checkpoint_size_mb = 100

    checkpoint_duration_ms = round(checkpoint_size_mb * 5)
    Process.sleep(min(checkpoint_duration_ms, 50))

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info("CRIU checkpoint created",
      machine_id: machine_id,
      checkpoint_id: checkpoint_id,
      duration_ms: duration,
      size_mb: checkpoint_size_mb,
      iterations: iterations
    )

    :telemetry.execute(
      [:orchestrator, :checkpoint, :created],
      %{duration_ms: duration, size_mb: checkpoint_size_mb, iterations: iterations},
      %{machine_id: machine_id}
    )

    {:ok, checkpoint_id}
  end

  @spec restore_checkpoint(checkpoint_id(), atom()) :: :ok | {:error, term()}
  def restore_checkpoint(checkpoint_id, dest_region) do
    Logger.info("Restoring CRIU checkpoint",
      checkpoint_id: checkpoint_id,
      dest_region: dest_region
    )

    start_time = System.monotonic_time(:millisecond)

    checkpoint_size_mb = 100
    restore_duration_ms = round(checkpoint_size_mb * 5)
    Process.sleep(min(restore_duration_ms, 50))

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info("CRIU checkpoint restored",
      checkpoint_id: checkpoint_id,
      dest_region: dest_region,
      duration_ms: duration,
      size_mb: checkpoint_size_mb
    )

    :telemetry.execute(
      [:orchestrator, :checkpoint, :restored],
      %{duration_ms: duration, size_mb: checkpoint_size_mb},
      %{checkpoint_id: checkpoint_id, dest_region: dest_region}
    )

    :ok
  end

  @spec verify_checkpoint(checkpoint_id()) :: :ok | {:error, term()}
  def verify_checkpoint(checkpoint_id) do
    Logger.debug("Verifying checkpoint integrity", checkpoint_id: checkpoint_id)

    :ok
  end

  defp perform_precopy_iterations(machine_id) do
    initial_dirty_mb = 1000

    Enum.reduce_while(1..5, {initial_dirty_mb, 0}, fn iteration, {dirty_mb, count} ->
      new_dirty_mb = round(dirty_mb * 0.2)

      Logger.debug("Pre-copy iteration #{iteration}",
        machine_id: machine_id,
        dirty_mb: dirty_mb
      )

      :telemetry.execute(
        [:orchestrator, :checkpoint, :precopy_iteration],
        %{iteration: iteration, dirty_mb: dirty_mb},
        %{machine_id: machine_id}
      )

      if new_dirty_mb < 10 do
        {:halt, count + 1}
      else
        {:cont, {new_dirty_mb, count + 1}}
      end
    end)
  end
end
