defmodule PhoenixUiWeb.TelemetryMetrics do
  use Supervisor
  import Telemetry.Metrics

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics(), name: PhoenixUiWeb.PrometheusExporter}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      last_value("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      counter("phoenix.endpoint.stop.count"),
      counter("aerophoenix.ui.actions.count"),
      counter("aerophoenix.orch.requests.count"),
      last_value("aerophoenix.orch.requests.duration", unit: {:native, :millisecond}),
      counter("aerophoenix.machines.updates"),
      last_value("aerophoenix.machines.count")
    ]
  end
end
