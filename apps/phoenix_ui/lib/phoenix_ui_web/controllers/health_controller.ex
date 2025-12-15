defmodule PhoenixUiWeb.HealthController do
  use PhoenixUiWeb, :controller

  def index(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{
      status: "ok",
      service: "phoenix_ui",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  def ready(conn, _params) do
    checks = [
      {:pubsub, check_pubsub()},
      {:processes, check_processes()},
      {:orchestrator, check_orchestrator()}
    ]

    all_healthy = Enum.all?(checks, fn {_, status} -> status == :ok end)

    status_code = if all_healthy, do: :ok, else: :service_unavailable

    conn
    |> put_status(status_code)
    |> json(%{
      status: if(all_healthy, do: "ready", else: "degraded"),
      service: "phoenix_ui",
      checks:
        Map.new(checks, fn {name, status} ->
          {name, %{status: to_string(status)}}
        end),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp check_pubsub do
    case Process.whereis(PhoenixUi.PubSub) do
      nil ->
        :error

      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: :error
    end
  end

  defp check_processes do
    required_processes = [
      PhoenixUi.PubSub,
      PhoenixUiWeb.Endpoint
    ]

    all_alive =
      Enum.all?(required_processes, fn name ->
        case Process.whereis(name) do
          nil -> false
          pid -> Process.alive?(pid)
        end
      end)

    if all_alive, do: :ok, else: :error
  end

  defp check_orchestrator do
    orchestrator_url =
      Application.get_env(:phoenix_ui, PhoenixUiWeb.OrchestratorClient)[:base_url]

    case orchestrator_url do
      nil ->
        :ok

      url ->
        Task.async(fn ->
          case Req.get("#{url}/api/v1/ping", receive_timeout: 2000) do
            {:ok, %{status: 200}} -> :ok
            _ -> :degraded
          end
        end)
        |> Task.await(3000)
    end
  rescue
    _ -> :degraded
  end
end
