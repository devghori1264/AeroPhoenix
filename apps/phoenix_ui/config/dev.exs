import Config

config :phoenix_ui, PhoenixUiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "yrdaGm5/rUkeRwQUbaq31EvjIq43TDNjfXTK0W3NHGCMyQ368xbir6pEAvNfIlKE",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:phoenix_ui, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:phoenix_ui, ~w(--watch)]}
  ]

config :phoenix_ui, PhoenixUiWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/phoenix_ui_web/(?:controllers|live|components|router)/?.*\.(ex|heex)$"
    ]
  ]

config :phoenix_ui, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318",
  otlp_headers: [],
  otlp_compression: :gzip
