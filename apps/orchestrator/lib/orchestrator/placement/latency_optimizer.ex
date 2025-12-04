defmodule Orchestrator.Placement.LatencyOptimizer do
  require Logger
  import Ecto.Query
  alias Orchestrator.{Repo, Machines.Machine}
  @default_latency_weight 0.4
  @default_affinity_weight 0.3
  @default_distribution_weight 0.3
  @latency_cache_ttl_seconds 300
  @simulated_annealing_iterations 1000
  @temperature_initial 100.0
  @temperature_decay 0.95
  defstruct [
    :latency_matrix,
    :affinity_rules,
    :anti_affinity_rules,
    :distribution_requirements,
    :optimization_mode,
    :weights,
    :constraints
  ]

  def optimize_placements(machines, options \\ []) do
    {:ok, candidates} = suggest_migrations(options)

    machine_ids = Enum.map(machines, & &1.id)
    relevant_candidates = Enum.filter(candidates, fn c -> c.machine.id in machine_ids end)

    total_improvement = Enum.reduce(relevant_candidates, 0.0, &(&1.improvement + &2))

    avg_improvement =
      if length(relevant_candidates) > 0,
        do: total_improvement / length(relevant_candidates),
        else: 0.0

    %{
      improved_placements: relevant_candidates,
      average_latency_improvement: avg_improvement
    }
  end

  def find_optimal_placement(machine_spec, options \\ []) do
    optimizer = build_optimizer(options)
    candidate_regions = get_candidate_regions(machine_spec, options)
    latency_matrix = load_latency_matrix(optimizer, candidate_regions)
    optimizer = %{optimizer | latency_matrix: latency_matrix}

    case optimizer.optimization_mode do
      :greedy ->
        greedy_placement(optimizer, machine_spec, candidate_regions)

      :simulated_annealing ->
        simulated_annealing_placement(optimizer, machine_spec, candidate_regions)

      :constraint_satisfaction ->
        constraint_satisfaction_placement(optimizer, machine_spec, candidate_regions)

      _ ->
        {:error, :invalid_optimization_mode}
    end
  end

  def evaluate_placement(machine) do
    optimizer = build_optimizer([])
    related_machines = get_related_machines(machine)
    latency_score = calculate_latency_score(optimizer, machine, related_machines)
    affinity_score = calculate_affinity_score(optimizer, machine, related_machines)
    distribution_score = calculate_distribution_score(machine)
    weights = optimizer.weights

    total_score =
      latency_score * weights.latency +
        affinity_score * weights.affinity +
        distribution_score * weights.distribution

    {:ok,
     %{
       total_score: total_score,
       latency_score: latency_score,
       affinity_score: affinity_score,
       distribution_score: distribution_score,
       recommendations: generate_recommendations(machine, total_score)
     }}
  end

  def suggest_migrations(options \\ []) do
    _optimizer = build_optimizer(options)
    threshold = options[:improvement_threshold] || 0.15
    machines = Repo.all(Machine)

    migration_candidates =
      machines
      |> Enum.map(fn machine ->
        {:ok, evaluation} = evaluate_placement(machine)

        case find_optimal_placement(%{}, region: machine.region) do
          {:ok, optimal_region, optimal_score} ->
            improvement = optimal_score.total_score - evaluation.total_score

            if improvement > threshold do
              %{
                machine: machine,
                current_region: machine.region,
                current_score: evaluation.total_score,
                optimal_region: optimal_region,
                optimal_score: optimal_score.total_score,
                improvement: improvement,
                estimated_migration_time: estimate_migration_time(machine, optimal_region)
              }
            else
              nil
            end

          _ ->
            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))
      |> Enum.sort_by(& &1.improvement, :desc)

    {:ok, migration_candidates}
  end

  defp greedy_placement(optimizer, machine_spec, candidate_regions) do
    scored_regions =
      candidate_regions
      |> Enum.map(fn region ->
        score = score_region(optimizer, region, machine_spec)
        {region, score}
      end)
      |> Enum.sort_by(fn {_region, score} -> score.total end, :desc)

    case scored_regions do
      [{best_region, best_score} | _] ->
        {:ok, best_region, best_score}

      [] ->
        {:error, :no_viable_regions}
    end
  end

  defp simulated_annealing_placement(optimizer, machine_spec, candidate_regions) do
    current_region = Enum.random(candidate_regions)
    current_score = score_region(optimizer, current_region, machine_spec)

    {best_region, best_score} =
      simulated_annealing_iterate(
        optimizer,
        machine_spec,
        candidate_regions,
        current_region,
        current_score,
        current_region,
        current_score,
        @temperature_initial,
        0
      )

    {:ok, best_region, best_score}
  end

  defp simulated_annealing_iterate(
         optimizer,
         machine_spec,
         candidate_regions,
         current_region,
         current_score,
         best_region,
         best_score,
         temperature,
         iteration
       ) do
    if iteration >= @simulated_annealing_iterations do
      {best_region, best_score}
    else
      neighbor_region = Enum.random(candidate_regions)
      neighbor_score = score_region(optimizer, neighbor_region, machine_spec)
      delta = neighbor_score.total - current_score.total

      accept_probability =
        if delta > 0 do
          1.0
        else
          :math.exp(delta / temperature)
        end

      {next_region, next_score, next_best_region, next_best_score} =
        if :rand.uniform() < accept_probability do
          next_best =
            if neighbor_score.total > best_score.total do
              {neighbor_region, neighbor_score}
            else
              {best_region, best_score}
            end

          {neighbor_region, neighbor_score, elem(next_best, 0), elem(next_best, 1)}
        else
          {current_region, current_score, best_region, best_score}
        end

      next_temperature = temperature * @temperature_decay

      simulated_annealing_iterate(
        optimizer,
        machine_spec,
        candidate_regions,
        next_region,
        next_score,
        next_best_region,
        next_best_score,
        next_temperature,
        iteration + 1
      )
    end
  end

  defp constraint_satisfaction_placement(optimizer, machine_spec, candidate_regions) do
    viable_regions =
      candidate_regions
      |> Enum.filter(&satisfies_hard_constraints?(optimizer, &1, machine_spec))

    if Enum.empty?(viable_regions) do
      {:error, :no_viable_regions}
    else
      greedy_placement(optimizer, machine_spec, viable_regions)
    end
  end

  defp score_region(optimizer, region, machine_spec) do
    related_machines = get_related_machines_for_spec(machine_spec)
    latency_score = score_latency(optimizer, region, related_machines)
    affinity_score = score_affinity(optimizer, region, machine_spec)
    distribution_score = score_distribution(region)
    weights = optimizer.weights

    total_score =
      latency_score * weights.latency +
        affinity_score * weights.affinity +
        distribution_score * weights.distribution

    %{
      total: total_score,
      latency: latency_score,
      affinity: affinity_score,
      distribution: distribution_score,
      breakdown: %{
        latency_details: get_latency_details(optimizer, region, related_machines),
        affinity_details: get_affinity_details(optimizer, region, machine_spec),
        distribution_details: get_distribution_details(region)
      }
    }
  end

  defp score_latency(optimizer, region, related_machines) do
    if Enum.empty?(related_machines) do
      1.0
    else
      latencies =
        related_machines
        |> Enum.map(fn machine ->
          get_latency(optimizer.latency_matrix, region, machine.region)
        end)

      avg_latency = Enum.sum(latencies) / length(latencies)
      p95_latency = percentile(latencies, 0.95)
      max_acceptable_latency = 200.0
      avg_score = max(0.0, 1.0 - avg_latency / max_acceptable_latency)
      p95_score = max(0.0, 1.0 - p95_latency / max_acceptable_latency)
      avg_score * 0.6 + p95_score * 0.4
    end
  end

  defp score_affinity(optimizer, region, _machine_spec) do
    affinity_rules = optimizer.affinity_rules || []
    anti_affinity_rules = optimizer.anti_affinity_rules || []

    if Enum.empty?(affinity_rules) && Enum.empty?(anti_affinity_rules) do
      1.0
    else
      affinity_score =
        affinity_rules
        |> Enum.map(fn {target_machine_id, strength} ->
          target_machine = Repo.get(Machine, target_machine_id)

          if target_machine && target_machine.region == region do
            strength
          else
            0.0
          end
        end)
        |> Enum.sum()

      anti_affinity_score =
        anti_affinity_rules
        |> Enum.map(fn {target_machine_id, strength} ->
          target_machine = Repo.get(Machine, target_machine_id)

          if target_machine && target_machine.region != region do
            strength
          else
            0.0
          end
        end)
        |> Enum.sum()

      total_rules = length(affinity_rules) + length(anti_affinity_rules)
      (affinity_score + anti_affinity_score) / max(total_rules, 1)
    end
  end

  defp score_distribution(region) do
    machines_in_region =
      Repo.aggregate(
        from(m in Machine, where: m.region == ^region),
        :count,
        :id
      )

    total_machines = Repo.aggregate(Machine, :count, :id)

    if total_machines == 0 do
      1.0
    else
      num_regions = Repo.aggregate(from(m in Machine, distinct: true, select: m.region), :count)
      ideal_per_region = total_machines / max(num_regions, 1)
      deviation = abs(machines_in_region - ideal_per_region)
      max(0.0, 1.0 - deviation / ideal_per_region)
    end
  end

  defp load_latency_matrix(_optimizer, regions) do
    case get_cached_latency_matrix() do
      {:ok, matrix} ->
        matrix

      :miss ->
        matrix = build_latency_matrix(regions)
        cache_latency_matrix(matrix)
        matrix
    end
  end

  defp build_latency_matrix(regions) do
    matrix =
      for from_region <- regions, into: %{} do
        row =
          for to_region <- regions, into: %{} do
            latency =
              if from_region == to_region do
                1.0
              else
                fetch_inter_region_latency(from_region, to_region)
              end

            {to_region, latency}
          end

        {from_region, row}
      end

    matrix
  end

  defp fetch_inter_region_latency(from_region, to_region) do
    case {from_region, to_region} do
      {"lax", "ord"} -> 55.0
      {"lax", "iad"} -> 70.0
      {"ord", "lax"} -> 55.0
      {"ord", "iad"} -> 25.0
      {"iad", "lax"} -> 70.0
      {"iad", "ord"} -> 25.0
      _ -> 100.0
    end
  end

  defp get_latency(matrix, from_region, to_region) do
    matrix
    |> Map.get(from_region, %{})
    |> Map.get(to_region, 100.0)
  end

  defp get_cached_latency_matrix do
    case :ets.lookup(:latency_cache, :matrix) do
      [{:matrix, matrix, timestamp}] ->
        if DateTime.diff(DateTime.utc_now(), timestamp, :second) < @latency_cache_ttl_seconds do
          {:ok, matrix}
        else
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_latency_matrix(matrix) do
    unless :ets.whereis(:latency_cache) != :undefined do
      :ets.new(:latency_cache, [:named_table, :public, :set])
    end

    :ets.insert(:latency_cache, {:matrix, matrix, DateTime.utc_now()})
  end

  defp satisfies_hard_constraints?(optimizer, region, machine_spec) do
    constraints = optimizer.constraints || %{}

    max_latency_satisfied =
      case constraints[:max_latency_ms] do
        nil ->
          true

        max_latency ->
          related_machines = get_related_machines_for_spec(machine_spec)

          Enum.all?(related_machines, fn machine ->
            latency = get_latency(optimizer.latency_matrix, region, machine.region)
            latency <= max_latency
          end)
      end

    region_allowed =
      case {constraints[:allowed_regions], constraints[:blocked_regions]} do
        {nil, nil} -> true
        {allowed, nil} -> region in allowed
        {nil, blocked} -> region not in blocked
        {allowed, blocked} -> region in allowed && region not in blocked
      end

    capacity_satisfied =
      case constraints[:min_capacity] do
        nil ->
          true

        min_capacity ->
          region_capacity = get_region_capacity(region)
          region_capacity >= min_capacity
      end

    max_latency_satisfied && region_allowed && capacity_satisfied
  end

  defp build_optimizer(options) do
    %__MODULE__{
      optimization_mode: options[:mode] || :greedy,
      weights: %{
        latency: options[:latency_weight] || @default_latency_weight,
        affinity: options[:affinity_weight] || @default_affinity_weight,
        distribution: options[:distribution_weight] || @default_distribution_weight
      },
      affinity_rules: options[:affinity_rules] || [],
      anti_affinity_rules: options[:anti_affinity_rules] || [],
      constraints: %{
        max_latency_ms: options[:max_latency_ms],
        allowed_regions: options[:allowed_regions],
        blocked_regions: options[:blocked_regions],
        min_capacity: options[:min_capacity]
      }
    }
  end

  defp get_candidate_regions(_machine_spec, options) do
    regions = options[:preferred_regions] || ["lax", "ord", "iad"]
    Enum.filter(regions, &region_available?/1)
  end

  defp region_available?(region) do
    valid_regions = ["us-east-1", "us-west-2", "eu-west-1", "ap-south-1", "lax", "ord", "iad"]
    region in valid_regions
  end

  defp get_related_machines(machine) do
    app_name = machine.metadata["app_name"]

    if app_name do
      Repo.all(
        from(m in Machine,
          where: fragment("metadata->>'app_name' = ?", ^app_name) and m.id != ^machine.id
        )
      )
    else
      []
    end
  end

  defp get_related_machines_for_spec(machine_spec) do
    app_name = machine_spec[:metadata]["app_name"] || machine_spec[:app_name]

    if app_name do
      Repo.all(from(m in Machine, where: fragment("metadata->>'app_name' = ?", ^app_name)))
    else
      []
    end
  end

  defp calculate_latency_score(optimizer, machine, related_machines) do
    score_latency(optimizer, machine.region, related_machines)
  end

  defp calculate_affinity_score(optimizer, machine, _related_machines) do
    score_affinity(optimizer, machine.region, %{metadata: machine.metadata})
  end

  defp calculate_distribution_score(machine) do
    score_distribution(machine.region)
  end

  defp generate_recommendations(machine, score) do
    if score < 0.5 do
      ["Consider migrating machine #{machine.id} to a region closer to related machines"]
    else
      []
    end
  end

  defp estimate_migration_time(machine, target_region) do
    disk_size_gb = String.to_integer(machine.metadata["disk_size_gb"] || "10")
    distance_factor = if machine.region == target_region, do: 1.0, else: 2.0

    minutes = round(disk_size_gb * distance_factor)
    "~#{minutes} minutes"
  end

  defp get_latency_details(optimizer, region, related_machines) do
    Enum.map(related_machines, fn m ->
      %{
        machine_id: m.id,
        region: m.region,
        latency: get_latency(optimizer.latency_matrix, region, m.region)
      }
    end)
  end

  defp get_affinity_details(optimizer, region, machine_spec) do
    %{
      affinity_score: score_affinity(optimizer, region, machine_spec),
      rules_matched: length(optimizer.affinity_rules)
    }
  end

  defp get_distribution_details(region) do
    %{
      region_capacity: get_region_capacity(region),
      current_load: score_distribution(region)
    }
  end

  defp get_region_capacity(_region) do
    1000
  end

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    index = trunc(p * length(sorted))
    Enum.at(sorted, index, 0.0)
  end
end
