import Config

if System.get_env("PHX_SERVER") do
  config :phoenix_ui, PhoenixUiWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :phoenix_ui, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :phoenix_ui, PhoenixUiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    check_origin: [
      "https://#{host}",
      "https://aerophoenix.fly.dev",
      "//#{host}",
      "//aerophoenix.fly.dev"
    ]

  orchestrator_url = System.get_env("ORCHESTRATOR_URL") || "http://localhost:4001"
  orchestrator_timeout = String.to_integer(System.get_env("ORCHESTRATOR_TIMEOUT") || "5000")
  orchestrator_token = System.get_env("ORCHESTRATOR_TOKEN") || "dev-token"

  config :phoenix_ui, PhoenixUiWeb.OrchestratorClient,
    base_url: orchestrator_url,
    request_timeout: orchestrator_timeout,
    token: orchestrator_token

  flyd_url = System.get_env("FLYD_SIM_URL") || "http://localhost:8080"
  config :phoenix_ui, :flyd_base, flyd_url

  topology_refresh = String.to_integer(System.get_env("PHX_TOPOLOGY_REFRESH_MS") || "5000")
  config :phoenix_ui, :topology, refresh_interval_ms: topology_refresh
end
