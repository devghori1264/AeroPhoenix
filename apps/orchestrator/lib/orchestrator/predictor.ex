defmodule Orchestrator.Predictor do
  @table :orch_predictor
  @threshold_percent 0.30
  def record_sample(machine_id, latency_ms)
      when is_binary(machine_id) and is_number(latency_ms) do
    samples =
      case :ets.lookup(@table, machine_id) do
        [{^machine_id, s}] -> s
        [] -> []
      end

    updated_samples = Enum.take([latency_ms | samples], 50)
    :ets.insert(@table, {machine_id, updated_samples})
    :ok
  end

  def should_migrate?(machine_id) when is_binary(machine_id) do
    case :ets.lookup(@table, machine_id) do
      [{^machine_id, samples}] when length(samples) >= 3 ->
        ema_alpha = Application.get_env(:orchestrator, __MODULE__, [])[:ema_alpha] || 0.2
        ema = compute_ema(samples, ema_alpha)
        baseline = region_baseline_estimate()

        if ema > baseline * (1 + @threshold_percent) do
          {:migrate, "ema_#{Float.round(ema, 1)}_above_baseline_#{baseline}"}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp region_baseline_estimate, do: 80.0

  defp compute_ema(list, alpha) when is_list(list) and is_float(alpha) do
    list
    |> Enum.reverse()
    |> Enum.reduce(nil, fn value, accumulator ->
      if is_nil(accumulator),
        do: value,
        else: accumulator * (1 - alpha) + value * alpha
    end)
    |> case do
      nil -> 0.0
      ema_value -> Float.round(ema_value, 2)
    end
  end
end
