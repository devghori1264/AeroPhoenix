defmodule Orchestrator.LiveMigration.CircuitBreaker do
  @moduledoc """
  Circuit breaker for live migration operations.
  Delegates to Orchestrator.Migration.CircuitBreaker.
  """

  defdelegate call(circuit_name, fun, opts \\ []), to: Orchestrator.Migration.CircuitBreaker
  defdelegate get_state(circuit_name), to: Orchestrator.Migration.CircuitBreaker
  defdelegate reset(circuit_name), to: Orchestrator.Migration.CircuitBreaker
  defdelegate get_stats(circuit_name), to: Orchestrator.Migration.CircuitBreaker
end
