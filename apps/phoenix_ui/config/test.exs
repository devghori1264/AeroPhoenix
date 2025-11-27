import Config

config :phoenix_ui, PhoenixUiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vSg5RTyYSVI/jLSo/0kCYqNDj8stLUvv4RG+x5eMkoOmP36DORP/mvRDYhHnFBEY",
  server: false

config :phoenix_ui, PhoenixUi.Mailer, adapter: Swoosh.Adapters.Test

config :swoosh, :api_client, false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true
