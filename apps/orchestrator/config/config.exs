import Config
config :orchestrator, ecto_repos: [Orchestrator.Repo]

config :orchestrator, http: [
  timeout: 5_000,
  recv_timeout: 5_000,
  base_url: System.get_env("FLYD_SIM_URL", "http://localhost:8080")
]

config :orchestrator, OrchestratorWeb.Endpoint,
  http: [port: 4001],
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  server: true,
  render_errors: [
    formats: [json: OrchestratorWeb.ErrorJSON],
    layout: false
  ]

config :orchestrator, Orchestrator.Predictor,
  ema_alpha: 0.2

import_config "#{Mix.env()}.exs"
