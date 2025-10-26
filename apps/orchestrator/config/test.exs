import Config

database_url =
  System.get_env("DATABASE_URL") ||
    "ecto://postgres:postgres@localhost:5432/orchestrator_test"

config :orchestrator, Orchestrator.Repo,
  url: database_url,
  pool_size: 5,
  show_sensitive_data_on_connection_error: true,
  log: false

config :logger, level: :info
