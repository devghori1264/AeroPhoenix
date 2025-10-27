defmodule PhoenixUi.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PhoenixUiWeb.Telemetry,
      {Phoenix.PubSub, name: PhoenixUi.PubSub, adapter: Phoenix.PubSub.PG2},
      PhoenixUiWeb.Endpoint,
      {Finch, name: PhoenixUiWeb.Finch},
      PhoenixUi.Machines,
      PhoenixUi.Predictive,
      PhoenixUiWeb.TelemetryMetrics,
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
    :otel_batch_processor.set_exporter(:otel_exporter_stdout, [])
    PhoenixUi.OpenTelemetrySetup.setup()
    :ok
  end
end
