defmodule Orchestrator.Migration.ConnectionDrainer do
  use GenServer
  require Logger

  @type machine_id :: String.t()
  @type drain_opts :: keyword()

  @default_timeout_ms 5_000
  @check_interval_ms 100

  @impl true
  def init(init_arg) do
    {:ok, init_arg}
  end

  @spec drain_connections(machine_id(), drain_opts()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def drain_connections(machine_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    check_interval = Keyword.get(opts, :check_interval, @check_interval_ms)

    Logger.info("Starting connection draining",
      machine_id: machine_id,
      timeout: timeout
    )

    start_time = System.monotonic_time(:millisecond)

    :ok = set_health_status(machine_id, :draining)

    Process.sleep(1000)

    :ok = send_close_signals(machine_id)

    deadline = System.monotonic_time(:millisecond) + timeout
    active_count = wait_for_connections_to_close(machine_id, deadline, check_interval)

    forced_closes =
      if active_count > 0 do
        Logger.warning("Force-closing remaining connections",
          machine_id: machine_id,
          count: active_count
        )

        force_close_all_connections(machine_id)
      else
        0
      end

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info("Connection draining completed",
      machine_id: machine_id,
      duration_ms: duration,
      forced_closes: forced_closes
    )

    :telemetry.execute(
      [:orchestrator, :draining, :completed],
      %{duration_ms: duration, forced_closes: forced_closes},
      %{machine_id: machine_id}
    )

    {:ok, forced_closes}
  end

  defp set_health_status(_machine_id, _status) do
    :ok
  end

  defp send_close_signals(_machine_id) do
    :ok
  end

  defp wait_for_connections_to_close(machine_id, deadline, check_interval) do
    Stream.iterate(0, & &1)
    |> Enum.reduce_while(nil, fn _iteration, _acc ->
      current_time = System.monotonic_time(:millisecond)

      if current_time >= deadline do
        active_count = get_active_connection_count(machine_id)
        {:halt, active_count}
      else
        active_count = get_active_connection_count(machine_id)

        if active_count == 0 do
          {:halt, 0}
        else
          Logger.debug("Waiting for connections to close",
            machine_id: machine_id,
            active: active_count,
            remaining_ms: deadline - current_time
          )

          Process.sleep(check_interval)
          {:cont, nil}
        end
      end
    end)
  end

  defp force_close_all_connections(machine_id) do
    connections = get_all_active_connections(machine_id)

    Enum.each(connections, fn {conn_id, metadata} ->
      Logger.debug("Force-closing connection",
        conn_id: conn_id,
        type: metadata[:type],
        duration_ms: System.monotonic_time(:millisecond) - metadata[:started_at]
      )

      force_close_connection(conn_id)
    end)

    length(connections)
  end

  defp get_active_connection_count(_machine_id) do
    0
  end

  defp get_all_active_connections(_machine_id) do
    []
  end

  defp force_close_connection(_conn_id) do
    :ok
  end
end
