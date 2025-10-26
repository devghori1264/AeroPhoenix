defmodule Orchestrator.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Orchestrator.Repo,
      {Finch, name: Orchestrator.Finch},
      {TelemetryMetricsPrometheus, metrics: Orchestrator.Metrics.metrics(), port: 9568, path: "/metrics"},
      Orchestrator.Manager,
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
end
