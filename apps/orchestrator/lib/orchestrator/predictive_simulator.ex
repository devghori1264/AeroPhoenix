defmodule Orchestrator.PredictiveSimulator do
  @spec simulate_plan([map()]) :: map()
  def simulate_plan(plan) when is_list(plan) do
    results =
      Enum.map(plan, fn %{"id" => id, "target_region" => target} ->
        case Orchestrator.Repo.get(Orchestrator.Machines.Machine, id) do
          nil ->
            %{id: id, error: "not_found"}

          _m ->
            {:ok, recs} = Orchestrator.PredictivePlanner.recommend_migrations(id)
            rec = Enum.find(recs, &(&1.region == target)) || hd(recs)
            Map.put(rec, "id", id)
        end
      end)

    avg_latency_delta =
      Enum.reduce(results, 0.0, fn r, acc ->
        acc + (r["avg_latency_delta"] || r.avg_latency_delta || 0.0)
      end) / max(1, length(results))

    %{
      summary: %{avg_latency_delta: avg_latency_delta},
      details: results
    }
  end
end
