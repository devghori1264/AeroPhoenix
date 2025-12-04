import Config

config :orchestrator, Orchestrator.Repo,
  pool_size: 10,
  ssl: false,
  show_sensitive_data_on_connection_error: false

config :orchestrator, OrchestratorWeb.Endpoint,
  http: [port: 4000],
  server: true,
  check_origin: false,
  render_errors: [
    formats: [json: OrchestratorWeb.ErrorJSON],
    layout: false
  ]

config :orchestrator, Oban,
  repo: Orchestrator.Repo,
  queues: [default: 10, events: 50, mailers: 20],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Orchestrator.FeatureFlags.Jobs.ExperimentAnalysisJob},
       {"*/10 * * * *", Orchestrator.Metrics.Jobs.AnomalyDetectionJob}
     ]}
  ]

config :logger, level: :warning

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
