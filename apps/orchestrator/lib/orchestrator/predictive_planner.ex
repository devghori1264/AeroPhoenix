defmodule Orchestrator.PredictivePlanner do
  import Ecto.Query

  @spec recommend_migrations(String.t(), keyword()) :: {:ok, list(map())}
  def recommend_migrations(machine_id, opts \\ []) do
    samples = opts[:samples] || 300
    alpha = opts[:alpha] || 1.0
    beta = opts[:beta] || 0.5
    gamma = opts[:gamma] || 0.2

    case Orchestrator.Repo.get(Orchestrator.Machine, machine_id) do
      nil ->
        {:error, :not_found}

      machine ->
        regions = candidate_regions_except(machine.region)

        results =
          regions
          |> Enum.map(fn region ->
            estimate_for_region(machine, region, samples, alpha, beta, gamma)
          end)
          |> Enum.sort_by(& &1.score, &>=/2)

        :telemetry.execute([:aerophoenix, :planner, :recommendation], %{runs: 1}, %{
          machine_id: machine_id
        })

        {:ok, results}
    end
  end

  defp candidate_regions_except(current) do
    Orchestrator.Repo.all(from(m in Orchestrator.Machine, select: m.region))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == current))
  end

  defp estimate_for_region(machine, region, samples, alpha, beta, gamma) do
    {avg_latency_delta, avg_cost_delta, risk} =
      1..samples
      |> Enum.reduce({0.0, 0.0, 0.0}, fn _, {lat_acc, cost_acc, risk_acc} ->
        noise = :rand.normal(0, 1)
        latency_src = machine.latency_ms + :rand.uniform(20) * noise
        base_link = estimated_link_latency(machine.region, region)
        new_latency = base_link + :rand.uniform(30)
        latency_delta = latency_src - new_latency

        cost_delta =
          (String.length(region) - String.length(machine.region)) * 0.1 + :rand.uniform() * 0.05

        risk_sample = if :rand.uniform() < 0.02, do: 1.0, else: 0.0
        {lat_acc + latency_delta, cost_acc + cost_delta, risk_acc + risk_sample}
      end)

    avg_latency_delta = avg_latency_delta / samples
    avg_cost_delta = avg_cost_delta / samples
    risk = risk / samples

    score = alpha * avg_latency_delta - beta * avg_cost_delta - gamma * risk

    %{
      region: region,
      avg_latency_delta: Float.round(avg_latency_delta, 2),
      avg_cost_delta: Float.round(avg_cost_delta, 4),
      risk: Float.round(risk, 4),
      score: Float.round(score, 4)
    }
  end

  defp estimated_link_latency(src, dst) do
    100 + abs(String.length(src) - String.length(dst)) * 5
  end
end
