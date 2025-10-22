defmodule Orchestrator.Application do
  @moduledoc """
  The main application module for the Orchestrator.

  Starts and supervises the core components:
  - Ecto Repo for database access.
  - Finch HTTP client pool for communicating with flyd-sim.
  - Telemetry Metrics Prometheus exporter.
  - The core Manager GenServer responsible for reconciliation.
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Define the children to be supervised.
    # Note: The Predictor's ETS table is now managed within Orchestrator.Manager.
    children = [
      # Start the Ecto repo
      Orchestrator.Repo,
      # Start the Finch HTTP client pool
      {Finch, name: Orchestrator.Finch},
      # Start the Prometheus metrics exporter
      {TelemetryMetricsPrometheus, metrics: Orchestrator.Metrics.metrics(), port: 9568, path: "/metrics"},
      # Start the core reconciliation manager
      Orchestrator.Manager
    ]

    # Configure the main supervisor
    opts = [strategy: :one_for_one, name: Orchestrator.Supervisor]

    # Start the supervisor and its children
    Supervisor.start_link(children, opts)
  end
end
