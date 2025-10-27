defmodule Orchestrator.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Orchestrator Application...")

    children = [
      Orchestrator.Repo,
      {Finch, name: Orchestrator.Finch},
      Orchestrator.MachineManager,
      Orchestrator.NatsListener,
      {TelemetryMetricsPrometheus,
        metrics: Orchestrator.Metrics.metrics(),
        port: telemetry_port(),
        path: "/metrics"},
      OrchestratorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Orchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    OrchestratorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp telemetry_port, do: String.to_integer(System.get_env("TELEMETRY_PORT", "9568"))
end
