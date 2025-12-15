defmodule PhoenixUi.Application do
  use Application

  @impl true
  def start(_type, _args) do
    :inet_db.set_lookup([:file, :native])

    finch_pools = %{
      :default => [
        size: 10,
        conn_opts: [
          transport_opts: [
            inet6: true
          ]
        ]
      ]
    }

    children = [
      PhoenixUiWeb.Telemetry,
      {Phoenix.PubSub, name: PhoenixUi.PubSub, adapter: Phoenix.PubSub.PG2},
      PhoenixUiWeb.Endpoint,
      {Finch, name: PhoenixUiWeb.Finch, pools: finch_pools},
      PhoenixUi.Machines,
      PhoenixUi.Predictive,
      PhoenixUiWeb.TelemetryMetrics,
      {Registry, keys: :unique, name: PhoenixUiWeb.SocketRegistry},
      {PhoenixUiWeb.NatsClient, []}
    ]

    setup_opentelemetry()
    opts = [strategy: :one_for_one, name: PhoenixUi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PhoenixUiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp setup_opentelemetry do
    PhoenixUi.OpenTelemetrySetup.setup()
    :ok
  end
end
