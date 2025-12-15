import Config

database_url =
  System.get_env("DATABASE_URL") ||
    "ecto://aerouser:aeropass@localhost:5432/orchestrator_test"

config :orchestrator, Orchestrator.Repo,
  url: database_url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 20,
  show_sensitive_data_on_connection_error: false,
  log: false,
  ownership_timeout: 240_000,
  timeout: 240_000

config :logger, level: :info
config :logger, :console, level: :warning

config :orchestrator, :env, :test

config :orchestrator, :partition_check_interval, 50

config :orchestrator, OrchestratorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

config :orchestrator, :flyd_client, Orchestrator.MockFlydClient

config :orchestrator, :holodeck,
  max_machines: 50,
  ramp_up_interval_ms: 1

config :orchestrator, :raft,
  election_timeout_ms: 50,
  heartbeat_interval_ms: 20

config :orchestrator, :scheduler,
  max_retries: 2,
  retry_backoff_ms: 1

config :orchestrator, :circuit_breaker,
  error_threshold: 50,
  reset_timeout_ms: 100

config :orchestrator, :machine_data_dir, "tmp/test_machines"
config :orchestrator, :machine_actor_data_dir, "tmp/test_machines"
config :orchestrator, :storage_path, "tmp/test_machines/"

config :orchestrator, :resource_manager,
  cpu_cores: 1000.0,
  memory_mb: 1_000_000,
  disk_mb: 10_000_000,
  leak_scan_interval_ms: 100

config :orchestrator, :reconciler_interval, 3_600_000
