defmodule OrchestratorWeb.MachineController do
  use OrchestratorWeb, :controller
  alias Orchestrator.Manager

  def index(conn, _params) do
    json(conn, Manager.list_machines())
  end

  def create(conn, %{"name" => name, "region" => region}) do
    {:ok, machine} = Manager.create_machine(name, region)
    json(conn, machine)
  end
end
