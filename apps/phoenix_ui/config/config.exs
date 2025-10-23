import Config

config :phoenix_ui,
  generators: [timestamp_type: :utc_datetime]

config :phoenix_ui, PhoenixUiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PhoenixUiWeb.ErrorHTML, json: PhoenixUiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PhoenixUi.PubSub,
  live_view: [signing_salt: "VJaTnrYa"]

config :phoenix_ui, PhoenixUi.Mailer, adapter: Swoosh.Adapters.Local

config :phoenix_ui, :flyd_base, System.get_env("FLYD_SIM_URL", "http://localhost:8080")

config :esbuild,
  version: "0.25.4",
  phoenix_ui: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.7",
  phoenix_ui: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
