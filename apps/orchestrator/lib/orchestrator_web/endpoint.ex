defmodule OrchestratorWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :orchestrator

  plug Plug.Static,
    at: "/",
    from: :orchestrator,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :orchestrator
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:orchestrator, :endpoint]
  plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], json_decoder: Phoenix.json_library()
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, store: :cookie, key: "_orchestrator_key", signing_salt: "123456"

  plug OrchestratorWeb.Router
end
