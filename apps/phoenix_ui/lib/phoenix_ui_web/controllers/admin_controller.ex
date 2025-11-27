defmodule PhoenixUiWeb.AdminController do
  use PhoenixUiWeb, :controller
  require Logger

  def kill_machine(conn, %{"machine_id" => machine_id} = params) do
    reason = Map.get(params, "reason", "Manual kill")
    operator = Map.get(params, "operator", "unknown")

    case Orchestrator.Security.KillSwitch.kill_machine(machine_id, reason: reason) do
      :ok ->
        Logger.warning("Machine killed via admin API",
          machine_id: machine_id,
          reason: reason,
          operator: operator
        )

        json(conn, %{
          status: "success",
          machine_id: machine_id,
          action: "killed",
          reason: reason
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "kill_failed",
          reason: inspect(reason)
        })
    end
  end

  def global_kill(conn, params) do
    scope = parse_scope(params["scope"])
    reason = params["reason"] || "Emergency stop"
    authorized_by = params["authorized_by"] || []

    opts = [
      scope: scope,
      reason: reason,
      authorized_by: authorized_by
    ]

    opts =
      case scope do
        :region -> Keyword.put(opts, :region, params["region"])
        :customer -> Keyword.put(opts, :customer_id, params["customer_id"])
        _ -> opts
      end

    case Orchestrator.Security.KillSwitch.global_kill(opts) do
      {:ok, killed_count} ->
        Logger.error("GLOBAL KILL executed via admin API",
          scope: scope,
          killed_count: killed_count,
          reason: reason,
          authorized_by: authorized_by
        )

        json(conn, %{
          status: "success",
          action: "global_kill",
          scope: scope,
          killed_count: killed_count,
          reason: reason,
          authorized_by: authorized_by
        })

      {:error, :insufficient_authorization} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "insufficient_authorization",
          message: "Global kill requires two-person authorization"
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "global_kill_failed",
          reason: inspect(reason)
        })
    end
  end

  def kill_audit_log(conn, params) do
    filters = []

    filters =
      if params["machine_id"],
        do: Keyword.put(filters, :machine_id, params["machine_id"]),
        else: filters

    events = Orchestrator.Security.KillSwitch.get_audit_log(filters)

    json(conn, %{
      events: events,
      count: length(events)
    })
  end

  def holodeck_spawn(conn, params) do
    count = params["count"] || 1000

    case Orchestrator.Testing.Holodeck.spawn_machines(count) do
      {:ok, machine_ids} ->
        json(conn, %{
          status: "success",
          spawned: length(machine_ids),
          machine_ids: Enum.take(machine_ids, 10)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "spawn_failed",
          reason: inspect(reason)
        })
    end
  end

  def holodeck_scenario(conn, params) do
    scenario = parse_scenario(params["scenario"])

    opts = []
    opts = if params["target"], do: Keyword.put(opts, :target, params["target"]), else: opts
    opts = if params["interval"], do: Keyword.put(opts, :interval, params["interval"]), else: opts
    opts = if params["count"], do: Keyword.put(opts, :count, params["count"]), else: opts
    opts = if params["duration"], do: Keyword.put(opts, :duration, params["duration"]), else: opts

    opts =
      if params["failure_rate"],
        do: Keyword.put(opts, :failure_rate, params["failure_rate"]),
        else: opts

    :ok = Orchestrator.Testing.Holodeck.run_scenario(scenario, opts)

    json(conn, %{
      status: "success",
      action: "scenario_started",
      scenario: scenario,
      options: opts
    })
  end

  def holodeck_metrics(conn, _params) do
    metrics = Orchestrator.Testing.Holodeck.report_metrics()

    json(conn, metrics)
  end

  def start_network_capture(conn, %{"machine_id" => machine_id} = params) do
    filter = Map.get(params, "filter")
    max_packets = Map.get(params, "max_packets", 10_000)
    full_payload = Map.get(params, "full_payload", false)

    options = [
      filter: filter,
      max_packets: max_packets,
      full_payload: full_payload
    ]

    case Orchestrator.Debugger.NetworkCapture.start(machine_id, options) do
      {:ok, capture_pid} ->
        Logger.info("Network capture started via admin API",
          machine_id: machine_id,
          filter: filter,
          pid: inspect(capture_pid)
        )

        json(conn, %{
          status: "success",
          machine_id: machine_id,
          capture_pid: inspect(capture_pid),
          filter: filter,
          max_packets: max_packets
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "capture_failed",
          reason: inspect(reason)
        })
    end
  end

  def stop_network_capture(conn, %{"machine_id" => machine_id}) do
    case Registry.lookup(Orchestrator.Registry, "network_capture_#{machine_id}") do
      [{capture_pid, _}] ->
        case Orchestrator.Debugger.NetworkCapture.stop(capture_pid) do
          {:ok, result} ->
            Logger.info("Network capture stopped via admin API",
              machine_id: machine_id,
              packets_captured: result.stats.packets_captured
            )

            json(conn, %{
              status: "success",
              machine_id: machine_id,
              packets_captured: result.stats.packets_captured,
              duration_seconds: result.duration_seconds
            })

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{
              error: "stop_failed",
              reason: inspect(reason)
            })
        end

      [] ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "no_capture_running",
          machine_id: machine_id
        })
    end
  end

  def network_capture_stats(conn, %{"machine_id" => machine_id}) do
    case Registry.lookup(Orchestrator.Registry, "network_capture_#{machine_id}") do
      [{capture_pid, _}] ->
        case Orchestrator.Debugger.NetworkCapture.get_stats(capture_pid) do
          {:ok, stats} ->
            json(conn, %{
              status: "success",
              machine_id: machine_id,
              stats: stats
            })

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{
              error: "stats_failed",
              reason: inspect(reason)
            })
        end

      [] ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "no_capture_running",
          machine_id: machine_id
        })
    end
  end

  def cluster_status(conn, _params) do
    status = Orchestrator.ResourceCoordinator.get_cluster_status()

    json(conn, status)
  end

  defp parse_scope("region"), do: :region
  defp parse_scope("cluster"), do: :cluster
  defp parse_scope("customer"), do: :customer
  defp parse_scope("machine"), do: :machine
  defp parse_scope(_), do: :machine

  defp parse_scenario("ramp_up"), do: :ramp_up
  defp parse_scenario("spike"), do: :spike
  defp parse_scenario("sustained"), do: :sustained
  defp parse_scenario("chaos"), do: :chaos
  defp parse_scenario(_), do: :spike
end
