import Config

if System.get_env("RELEASE_NAME") && config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL environment variable is not set"

  config :orchestrator, Orchestrator.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: if(System.get_env("ECTO_IPV6") == "true", do: [:inet6], else: [])

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is not set"

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4001")

  config :orchestrator, OrchestratorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  nats_url = System.get_env("NATS_URL") || "nats://nats:4222"

  [nats_host, nats_port] =
    case String.split(nats_url, "://") do
      ["nats", rest] ->
        case String.split(rest, ":") do
          [host, port] -> [host, String.to_integer(port)]
          [host] -> [host, 4222]
        end

      _ ->
        ["nats", 4222]
    end

  config :gnat,
    connection_settings: [
      %{host: nats_host, port: nats_port}
    ]
end
