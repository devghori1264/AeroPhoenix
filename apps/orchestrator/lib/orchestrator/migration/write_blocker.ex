defmodule Orchestrator.Migration.WriteBlocker do
  require Logger

  @type machine_id :: String.t()
  @type drain_result :: {:ok, map()} | {:error, term()}

  @default_drain_timeout_ms 5_000
  @drain_poll_interval_ms 10

  @spec block_writes(machine_id(), keyword()) :: drain_result()
  def block_writes(machine_id, opts \\ []) do
    drain_timeout = Keyword.get(opts, :drain_timeout, @default_drain_timeout_ms)
    force_close = Keyword.get(opts, :force_close, false)

    Logger.info("Blocking writes and draining requests",
      machine_id: machine_id,
      drain_timeout_ms: drain_timeout
    )

    case set_read_only_mode(machine_id) do
      :ok ->
        in_flight_at_start = get_in_flight_count(machine_id)

        Logger.debug("Read-only mode set",
          machine_id: machine_id,
          in_flight_requests: in_flight_at_start
        )

        drain_start = System.monotonic_time(:millisecond)

        case wait_for_drain(machine_id, drain_timeout, drain_start) do
          {:ok, drain_duration} ->
            stats = %{
              requests_drained: in_flight_at_start,
              duration_ms: drain_duration,
              forced_close: false
            }

            Logger.info("Drain complete",
              machine_id: machine_id,
              stats: stats
            )

            :telemetry.execute(
              [:orchestrator, :migration, :drain_complete],
              stats,
              %{machine_id: machine_id}
            )

            {:ok, stats}

          {:error, :timeout} ->
            in_flight_remaining = get_in_flight_count(machine_id)

            Logger.warning("Drain timeout",
              machine_id: machine_id,
              timeout_ms: drain_timeout,
              in_flight_remaining: in_flight_remaining
            )

            if force_close do
              force_close_connections(machine_id)

              stats = %{
                requests_drained: in_flight_at_start - in_flight_remaining,
                duration_ms: drain_timeout,
                forced_close: true,
                forced_close_count: in_flight_remaining
              }

              Logger.warning("Forced connection close",
                machine_id: machine_id,
                connections_closed: in_flight_remaining
              )

              {:ok, stats}
            else
              {:error, :drain_timeout}
            end
        end
    end
  end

  @spec unblock_writes(machine_id()) :: :ok | {:error, term()}
  def unblock_writes(machine_id) do
    Logger.info("Unblocking writes (resuming normal operation)",
      machine_id: machine_id
    )

    case set_read_write_mode(machine_id) do
      :ok ->
        :telemetry.execute(
          [:orchestrator, :migration, :writes_resumed],
          %{},
          %{machine_id: machine_id}
        )

        :ok
    end
  end

  defp set_read_only_mode(machine_id) do
    Logger.debug("Setting read-only mode", machine_id: machine_id)

    Process.put({:machine_mode, machine_id}, :read_only)

    :ok
  end

  defp set_read_write_mode(machine_id) do
    Logger.debug("Setting read-write mode", machine_id: machine_id)

    Process.put({:machine_mode, machine_id}, :read_write)

    :ok
  end

  defp wait_for_drain(machine_id, timeout_ms, drain_start) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_for_drain(machine_id, deadline, drain_start)
  end

  defp do_wait_for_drain(machine_id, deadline, drain_start) do
    now = System.monotonic_time(:millisecond)
    in_flight = get_in_flight_count(machine_id)

    cond do
      in_flight == 0 ->
        drain_duration = now - drain_start
        {:ok, drain_duration}

      now >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(@drain_poll_interval_ms)
        do_wait_for_drain(machine_id, deadline, drain_start)
    end
  end

  defp get_in_flight_count(_machine_id) do
    current_count = Process.get(:simulated_in_flight, nil)

    if current_count == nil do
      initial = :rand.uniform(6) + 2
      Process.put(:simulated_in_flight, initial)
      initial
    else
      decrease = :rand.uniform(2)
      new_count = max(0, current_count - decrease)
      Process.put(:simulated_in_flight, new_count)
      new_count
    end
  end

  defp force_close_connections(machine_id) do
    Logger.warning("Force closing connections (aggressive drain)",
      machine_id: machine_id
    )

    :ok
  end
end
