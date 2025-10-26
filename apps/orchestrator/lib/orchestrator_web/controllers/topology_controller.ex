defmodule OrchestratorWeb.TopologyController do
  use OrchestratorWeb, :controller
  alias Orchestrator.Manager

  def index(conn, _params) do
    topo = Manager.topology()
    json(conn, topo)
  end
end
