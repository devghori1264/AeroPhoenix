defmodule Orchestrator.Predictor do
  @moduledoc """
  A utility module for calculating predictive signals based on latency samples.

  - Reads latency samples stored in a shared ETS table (expected to be managed elsewhere).
  - Computes an exponential moving average (EMA) using standard Elixir functions.
  - Compares EMA against a baseline to determine if a migration should be suggested.

  Note: This module is stateless and relies on an external process managing the ETS table.
  """

  # Removed: use GenServer
  # Removed: require Logger (no longer needed directly)
  # Removed: alias Nx.Defn (Nx dependency is not used)

  # ETS table name where latency samples are stored.
  @table :orch_predictor
  # Migration threshold: EMA must be this percentage above baseline.
  @threshold_percent 0.30

  ## ─────────────────────────────
  ## Public API
  ## ─────────────────────────────

  # Removed: start_link(_opts) function

  @doc """
  Records a new latency sample for a given machine ID into the ETS table.

  This function directly interacts with the ETS table. It expects the table
  to exist and be managed by another process (e.g., Orchestrator.Manager).
  """
  def record_sample(machine_id, latency_ms)
      when is_binary(machine_id) and is_number(latency_ms) do
    # Directly interact with ETS table instead of GenServer.cast
    samples =
      case :ets.lookup(@table, machine_id) do
        # Found existing samples for the machine
        [{^machine_id, s}] -> s
        # No samples found, start with an empty list
        [] -> []
      end

    # Prepend the new sample and keep only the last 50
    updated_samples = Enum.take([latency_ms | samples], 50)

    # Insert/update the record in ETS
    :ets.insert(@table, {machine_id, updated_samples})

    :ok
  end

  @doc """
  Checks if a migration should be suggested based on recent latency samples.

  Reads samples from ETS, computes EMA, and compares to a baseline.
  Returns `{:migrate, reason :: String.t()}` or `:ok`.
  """
  def should_migrate?(machine_id) when is_binary(machine_id) do
    case :ets.lookup(@table, machine_id) do
      # Ensure we have enough samples for a meaningful EMA
      [{^machine_id, samples}] when length(samples) >= 3 ->
        # Fetch alpha value from application config, with a default
        ema_alpha = Application.get_env(:orchestrator, __MODULE__, [])[:ema_alpha] || 0.2

        # Compute the EMA
        ema = compute_ema(samples, ema_alpha)
        # Get the baseline estimate (currently hardcoded)
        baseline = region_baseline_estimate()

        # Check if EMA exceeds the threshold
        if ema > baseline * (1 + @threshold_percent) do
          {:migrate, "ema_#{Float.round(ema, 1)}_above_baseline_#{baseline}"}
        else
          :ok # EMA is within acceptable range
        end

      # Not enough samples or machine not found in ETS
      _ ->
        :ok
    end
  end

  ## ─────────────────────────────
  ## GenServer Callbacks (Removed)
  ## ─────────────────────────────
  # Removed: init(state) function
  # Removed: handle_cast({:record_sample, ...}) function

  ## ─────────────────────────────
  ## Internal Helpers
  ## ─────────────────────────────

  # Simple hardcoded baseline for now. In reality, this could be dynamic per region.
  defp region_baseline_estimate, do: 80.0

  # Computes the Exponential Moving Average using Enum.reduce.
  defp compute_ema(list, alpha) when is_list(list) and is_float(alpha) do
    list
    # Process samples from oldest to newest for correct EMA calculation
    |> Enum.reverse()
    # Use reduce to calculate the EMA iteratively
    |> Enum.reduce(nil, fn value, accumulator ->
        # The first value initializes the accumulator
        if is_nil(accumulator),
          do: value,
          else: accumulator * (1 - alpha) + value * alpha # Standard EMA formula
    end)
    # Handle the case where the list was empty or calculation resulted in nil
    |> case do
      nil -> 0.0 # Return 0.0 for empty list
      ema_value -> Float.round(ema_value, 2) # Round the result
    end
  end
end
