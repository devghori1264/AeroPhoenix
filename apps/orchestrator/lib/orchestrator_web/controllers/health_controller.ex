defmodule OrchestratorWeb.HealthController do
  use OrchestratorWeb, :controller

  def ping(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def health(conn, _params) do
    json(conn, %{status: "healthy", timestamp: DateTime.utc_now()})
  end
end
