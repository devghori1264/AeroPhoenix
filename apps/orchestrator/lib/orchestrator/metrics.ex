defmodule Orchestrator.Metrics do
  @moduledoc """
  Defines Telemetry metrics for the Orchestrator application.
  These metrics are exposed via the Prometheus exporter.
  """
  import Telemetry.Metrics

  @doc """
  Returns a list of Telemetry.Metrics definitions.
  """
  def metrics do
    [
      # Changed from summary to last_value to resolve Prometheus compatibility warning.
      # This captures the duration of the last reconciliation run.
      last_value("orchestrator.reconcile.duration_ms",
        reporter_options: [
          description: "Duration of the last reconciliation loop execution in milliseconds."
        ]
      ),

      # Counts the total number of reconciliation runs.
      counter("orchestrator.reconcile.runs",
        unit: :count,
        reporter_options: [
          description: "Total number of reconciliation loops executed."
        ]
      ),

      # Tracks the current number of machines known to the orchestrator (gauge).
      last_value("orchestrator.machines.count",
        reporter_options: [
          description: "Current count of machines managed by the orchestrator (excluding terminated)."
        ]
      )

      # Consider adding more metrics later, e.g.,
      # - counter("orchestrator.machines.created")
      # - counter("orchestrator.reconciliation.errors", tags: [:machine_id, :error_type])
      # - counter("orchestrator.migrations.suggested", tags: [:machine_id, :reason])
      # - summary("orchestrator.client.request.duration_ms", tags: [:endpoint])
    ]
  end
end
