defmodule OrchestratorWeb.Router do
  use OrchestratorWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", OrchestratorWeb do
    pipe_through :api
    get "/ping", HealthController, :ping
    get "/topology", TopologyController, :index
    get "/machines", MachineController, :index
    post "/machines", MachineController, :create
  end
end
