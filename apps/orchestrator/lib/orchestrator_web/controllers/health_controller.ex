defmodule OrchestratorWeb.HealthController do
  use OrchestratorWeb, :controller

  def ping(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
