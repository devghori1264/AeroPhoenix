import Config

config :orchestrator, Orchestrator.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  database: System.get_env("POSTGRES_DB", "aerophoenix_orch_dev"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool_size: 10

config :orchestrator, OrchestratorWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("ORCH_PORT", "4001"))],
  server: true

config :orchestrator, :nats,
  url: System.get_env("NATS_URL", "nats://localhost:4222")

config :orchestrator, :flyd,
  url: System.get_env("FLYD_URL", "http://localhost:8080")
