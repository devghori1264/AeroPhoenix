defmodule OrchestratorWeb.PingController do
  use OrchestratorWeb, :controller

  def index(conn, _params) do
    json(conn, %{msg: "pong from orchestrator"})
  end
end
