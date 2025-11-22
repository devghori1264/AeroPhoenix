defmodule Orchestrator.Metrics do
  import Telemetry.Metrics

  def metrics do
    [
      last_value("orchestrator.reconcile.duration_ms",
        reporter_options: [
          description: "Duration of the last reconciliation loop execution in milliseconds."
        ]
      ),
      counter("orchestrator.reconcile.runs",
        unit: :count,
        reporter_options: [
          description: "Total number of reconciliation loops executed."
        ]
      ),
      last_value("orchestrator.machines.count",
        reporter_options: [
          description:
            "Current count of machines managed by the orchestrator (excluding terminated)."
        ]
      )
    ]
  end
end
