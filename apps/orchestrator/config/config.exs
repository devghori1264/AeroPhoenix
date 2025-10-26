import Config

config :orchestrator, Orchestrator.Repo,
  username: System.get_env("POSTGRES_USER", "aerouser"),
  password: System.get_env("POSTGRES_PASSWORD", "aeropass"),
  database: System.get_env("POSTGRES_DB", "aerophoenix_dev"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool_size: 10

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
