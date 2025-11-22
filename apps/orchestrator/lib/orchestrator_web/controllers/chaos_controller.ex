defmodule OrchestratorWeb.ChaosController do
  use OrchestratorWeb, :controller
  alias Orchestrator.ChaosEngine

  def list_active(conn, _params) do
    active = ChaosEngine.list_active()

    incidents =
      Enum.map(active, fn incident ->
        %{
          id: incident.id,
          kind: incident.kind,
          target: incident.target,
          severity: incident.severity,
          started_at: incident.started_at,
          payload: incident.payload || %{}
        }
      end)

    json(conn, %{incidents: incidents})
  end

  def start(conn, params) do
    case ChaosEngine.start_scenario(params) do
      {:ok, incident} ->
        json(conn, %{
          status: "started",
          incident: %{
            id: incident.id,
            kind: incident.kind,
            target: incident.target,
            severity: incident.severity,
            started_at: incident.started_at
          }
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: inspect(reason)})
    end
  end

  def stop(conn, %{"id" => id}) do
    case ChaosEngine.stop_scenario(id) do
      {:ok, incident} ->
        json(conn, %{
          status: "stopped",
          incident: %{
            id: incident.id,
            ended_at: incident.ended_at
          }
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Incident not found"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: inspect(reason)})
    end
  end
end
