defmodule Orchestrator.Placement.CostOptimizer do
  require Logger
  alias Orchestrator.{Repo, Machines.Machine}
  @cpu_weight 0.4
  @memory_weight 0.4
  @disk_weight 0.1
  @network_weight 0.1
  @consolidation_threshold 0.7
  defstruct [
    :bin_packing_algorithm,
    :cost_model,
    :budget_constraints,
    :resource_prices,
    :consolidation_mode,
    :spot_instance_enabled,
    :reserved_capacity
  ]

  def analyze_cost_savings(machines, options \\ []) do
    {:ok, rightsizing} = recommend_rightsizing(options)
    machine_ids = Enum.map(machines, & &1.id)
    relevant_recs = Enum.filter(rightsizing, fn r -> r.machine_id in machine_ids end)

    total_savings =
      Enum.reduce(relevant_recs, Decimal.new("0.0"), fn r, acc ->
        Decimal.add(acc, Decimal.from_float(r.potential_savings_usd))
      end)

    %{
      recommendations: relevant_recs,
      total_monthly_savings: total_savings
    }
  end

  def find_cost_optimal_placement(machine_spec, options \\ []) do
    optimizer = build_optimizer(options)
    resources = extract_resource_requirements(machine_spec)
    candidate_hosts = find_candidate_hosts(resources, options)

    case optimizer.bin_packing_algorithm do
      :best_fit ->
        best_fit_placement(optimizer, resources, candidate_hosts)

      :first_fit ->
        first_fit_placement(optimizer, resources, candidate_hosts)

      :worst_fit ->
        worst_fit_placement(optimizer, resources, candidate_hosts)

      :next_fit ->
        next_fit_placement(optimizer, resources, candidate_hosts)

      _ ->
        {:error, :invalid_algorithm}
    end
  end

  def recommend_consolidations(options \\ []) do
    optimizer = build_optimizer(options)
    min_savings = options[:min_savings_percent] || 10.0
    hosts = load_hosts_with_utilization()

    underutilized =
      hosts
      |> Enum.filter(&underutilized?(&1, optimizer))
      |> Enum.sort_by(& &1.utilization.total_percent)

    consolidation_plans =
      underutilized
      |> Enum.flat_map(fn host ->
        generate_consolidation_plans(optimizer, host, hosts)
      end)
      |> Enum.filter(fn plan ->
        plan.estimated_savings_percent >= min_savings
      end)
      |> Enum.sort_by(& &1.estimated_savings_usd, :desc)

    {:ok, consolidation_plans}
  end

  def recommend_rightsizing(options \\ []) do
    lookback_days = options[:lookback_days] || 7
    machines = Repo.all(Machine)

    recommendations =
      machines
      |> Enum.map(fn machine ->
        analyze_machine_sizing(machine, lookback_days)
      end)
      |> Enum.filter(&(&1.recommendation != :optimal))
      |> Enum.sort_by(& &1.potential_savings_usd, :desc)

    {:ok, recommendations}
  end

  def calculate_total_cost(options \\ []) do
    optimizer = build_optimizer(options)
    machines = Repo.all(Machine)

    machine_costs =
      machines
      |> Enum.map(fn machine ->
        cost_per_hour = calculate_machine_cost(optimizer, machine)

        %{
          machine_id: machine.id,
          region: machine.region,
          cost_per_hour: cost_per_hour,
          cost_per_day: cost_per_hour * 24,
          cost_per_month: cost_per_hour * 24 * 30,
          breakdown: cost_breakdown(optimizer, machine)
        }
      end)

    total_cost_per_hour = Enum.sum(Enum.map(machine_costs, & &1.cost_per_hour))

    by_region =
      machine_costs
      |> Enum.group_by(& &1.region)
      |> Enum.map(fn {region, costs} ->
        {region, Enum.sum(Enum.map(costs, & &1.cost_per_hour))}
      end)
      |> Enum.into(%{})

    {:ok,
     %{
       total_per_hour: total_cost_per_hour,
       total_per_day: total_cost_per_hour * 24,
       total_per_month: total_cost_per_hour * 24 * 30,
       by_region: by_region,
       machine_costs: machine_costs,
       forecast: forecast_costs(machine_costs)
     }}
  end

  def enforce_budget(budget_limit, period, options \\ []) do
    {:ok, cost_analysis} = calculate_total_cost(options)

    current_cost =
      case period do
        :hourly -> cost_analysis.total_per_hour
        :daily -> cost_analysis.total_per_day
        :monthly -> cost_analysis.total_per_month
      end

    if current_cost > budget_limit do
      overage = current_cost - budget_limit
      overage_percent = overage / budget_limit * 100
      recommendations = generate_cost_reduction_recommendations(overage, options)

      {:over_budget,
       %{
         budget_limit: budget_limit,
         current_cost: current_cost,
         overage: overage,
         overage_percent: overage_percent,
         recommendations: recommendations
       }}
    else
      remaining = budget_limit - current_cost
      remaining_percent = remaining / budget_limit * 100

      {:within_budget,
       %{
         budget_limit: budget_limit,
         current_cost: current_cost,
         remaining: remaining,
         remaining_percent: remaining_percent
       }}
    end
  end

  defp best_fit_placement(optimizer, resources, candidate_hosts) do
    suitable_hosts =
      candidate_hosts
      |> Enum.filter(&can_fit?(resources, &1))
      |> Enum.map(fn host ->
        remaining = calculate_remaining_resources(host, resources)
        waste_score = calculate_waste_score(remaining)
        {host, waste_score}
      end)
      |> Enum.sort_by(fn {_host, score} -> score end)

    case suitable_hosts do
      [{best_host, _score} | _] ->
        cost = calculate_placement_cost(optimizer, best_host, resources)

        {:ok,
         %{
           host: best_host,
           estimated_cost_per_hour: cost,
           algorithm: :best_fit,
           fragmentation_score: calculate_host_fragmentation(best_host, resources)
         }}

      [] ->
        {:ok, new_host} = provision_new_host(optimizer, resources)
        cost = calculate_placement_cost(optimizer, new_host, resources)

        {:ok,
         %{
           host: new_host,
           estimated_cost_per_hour: cost,
           algorithm: :best_fit,
           new_host: true
         }}
    end
  end

  defp first_fit_placement(optimizer, resources, candidate_hosts) do
    case Enum.find(candidate_hosts, &can_fit?(resources, &1)) do
      nil ->
        {:ok, new_host} = provision_new_host(optimizer, resources)
        cost = calculate_placement_cost(optimizer, new_host, resources)

        {:ok,
         %{
           host: new_host,
           estimated_cost_per_hour: cost,
           algorithm: :first_fit,
           new_host: true
         }}

      first_host ->
        cost = calculate_placement_cost(optimizer, first_host, resources)

        {:ok,
         %{
           host: first_host,
           estimated_cost_per_hour: cost,
           algorithm: :first_fit
         }}
    end
  end

  defp worst_fit_placement(optimizer, resources, candidate_hosts) do
    suitable_hosts =
      candidate_hosts
      |> Enum.filter(&can_fit?(resources, &1))
      |> Enum.map(fn host ->
        remaining = calculate_remaining_resources(host, resources)
        capacity_score = calculate_capacity_score(remaining)
        {host, capacity_score}
      end)
      |> Enum.sort_by(fn {_host, score} -> score end, :desc)

    case suitable_hosts do
      [{worst_host, _score} | _] ->
        cost = calculate_placement_cost(optimizer, worst_host, resources)

        {:ok,
         %{
           host: worst_host,
           estimated_cost_per_hour: cost,
           algorithm: :worst_fit
         }}

      [] ->
        {:ok, new_host} = provision_new_host(optimizer, resources)
        cost = calculate_placement_cost(optimizer, new_host, resources)

        {:ok,
         %{
           host: new_host,
           estimated_cost_per_hour: cost,
           algorithm: :worst_fit,
           new_host: true
         }}
    end
  end

  defp next_fit_placement(optimizer, resources, candidate_hosts) do
    first_fit_placement(optimizer, resources, candidate_hosts)
  end

  defp extract_resource_requirements(machine_spec) do
    %{
      cpu_cores: machine_spec[:cpu_cores] || 1,
      memory_gb: machine_spec[:memory_gb] || 1,
      disk_gb: machine_spec[:disk_gb] || 10,
      network_mbps: machine_spec[:network_mbps] || 100
    }
  end

  defp can_fit?(resources, host) do
    available = host.available_resources

    resources.cpu_cores <= available.cpu_cores &&
      resources.memory_gb <= available.memory_gb &&
      resources.disk_gb <= available.disk_gb &&
      resources.network_mbps <= available.network_mbps
  end

  defp calculate_remaining_resources(host, resources) do
    available = host.available_resources

    %{
      cpu_cores: available.cpu_cores - resources.cpu_cores,
      memory_gb: available.memory_gb - resources.memory_gb,
      disk_gb: available.disk_gb - resources.disk_gb,
      network_mbps: available.network_mbps - resources.network_mbps
    }
  end

  defp calculate_waste_score(remaining) do
    cpu_waste = remaining.cpu_cores * @cpu_weight
    memory_waste = remaining.memory_gb * @memory_weight
    disk_waste = remaining.disk_gb * @disk_weight
    network_waste = remaining.network_mbps * @network_weight
    cpu_waste + memory_waste + disk_waste + network_waste
  end

  defp calculate_capacity_score(remaining) do
    cpu_score = remaining.cpu_cores * @cpu_weight
    memory_score = remaining.memory_gb * @memory_weight
    disk_score = remaining.disk_gb * @disk_weight
    network_score = remaining.network_mbps * @network_weight
    cpu_score + memory_score + disk_score + network_score
  end

  defp calculate_host_fragmentation(host, new_resources) do
    remaining = calculate_remaining_resources(host, new_resources)
    total_capacity = host.total_resources
    cpu_util = 1.0 - remaining.cpu_cores / total_capacity.cpu_cores
    mem_util = 1.0 - remaining.memory_gb / total_capacity.memory_gb
    disk_util = 1.0 - remaining.disk_gb / total_capacity.disk_gb
    net_util = 1.0 - remaining.network_mbps / total_capacity.network_mbps
    utils = [cpu_util, mem_util, disk_util, net_util]
    mean = Enum.sum(utils) / length(utils)
    variance = Enum.sum(Enum.map(utils, fn u -> (u - mean) * (u - mean) end)) / length(utils)
    :math.sqrt(variance)
  end

  defp calculate_machine_cost(optimizer, machine) do
    prices = optimizer.resource_prices
    cpu_cost = (machine.cpu_cores || 1) * prices.cpu_per_core_per_hour
    memory_cost = (machine.memory_gb || 1) * prices.memory_per_gb_per_hour
    disk_cost = (machine.disk_gb || 10) * prices.disk_per_gb_per_hour
    network_cost = (machine.network_mbps || 100) * prices.network_per_mbps_per_hour
    region_multiplier = get_region_price_multiplier(machine.region)
    base_cost = (cpu_cost + memory_cost + disk_cost + network_cost) * region_multiplier

    if machine.spot_instance do
      base_cost * 0.3
    else
      base_cost
    end
  end

  defp calculate_placement_cost(optimizer, host, resources) do
    prices = optimizer.resource_prices
    cpu_cost = resources.cpu_cores * prices.cpu_per_core_per_hour
    memory_cost = resources.memory_gb * prices.memory_per_gb_per_hour
    disk_cost = resources.disk_gb * prices.disk_per_gb_per_hour
    network_cost = resources.network_mbps * prices.network_per_mbps_per_hour
    region_multiplier = get_region_price_multiplier(host.region)
    (cpu_cost + memory_cost + disk_cost + network_cost) * region_multiplier
  end

  defp cost_breakdown(optimizer, machine) do
    prices = optimizer.resource_prices
    region_multiplier = get_region_price_multiplier(machine.region)

    %{
      cpu: (machine.cpu_cores || 1) * prices.cpu_per_core_per_hour * region_multiplier,
      memory: (machine.memory_gb || 1) * prices.memory_per_gb_per_hour * region_multiplier,
      disk: (machine.disk_gb || 10) * prices.disk_per_gb_per_hour * region_multiplier,
      network:
        (machine.network_mbps || 100) * prices.network_per_mbps_per_hour * region_multiplier
    }
  end

  defp get_region_price_multiplier(region) do
    case region do
      "lax" -> 1.0
      "ord" -> 0.95
      "iad" -> 1.05
      _ -> 1.0
    end
  end

  defp load_hosts_with_utilization do
    []
  end

  defp underutilized?(host, _optimizer) do
    utilization = host.utilization.total_percent
    utilization < @consolidation_threshold
  end

  defp generate_consolidation_plans(optimizer, source_host, target_hosts) do
    machines_on_source = get_machines_on_host(source_host)

    target_hosts
    |> Enum.filter(&(&1.id != source_host.id))
    |> Enum.flat_map(fn target_host ->
      if can_fit_all_machines?(machines_on_source, target_host) do
        current_cost =
          calculate_host_cost(optimizer, source_host) +
            calculate_host_cost(optimizer, target_host)

        new_cost = calculate_host_cost(optimizer, target_host)
        savings = current_cost - new_cost
        savings_percent = savings / current_cost * 100

        [
          %{
            source_host: source_host.id,
            target_host: target_host.id,
            machines_to_migrate: Enum.map(machines_on_source, & &1.id),
            estimated_savings_usd: savings,
            estimated_savings_percent: savings_percent,
            migration_complexity: :low
          }
        ]
      else
        []
      end
    end)
  end

  defp get_machines_on_host(_host) do
    []
  end

  defp can_fit_all_machines?(machines, target_host) do
    total_resources =
      Enum.reduce(
        machines,
        %{cpu_cores: 0, memory_gb: 0, disk_gb: 0, network_mbps: 0},
        fn machine, acc ->
          %{
            cpu_cores: acc.cpu_cores + (machine.cpu_cores || 1),
            memory_gb: acc.memory_gb + (machine.memory_gb || 1),
            disk_gb: acc.disk_gb + (machine.disk_gb || 10),
            network_mbps: acc.network_mbps + (machine.network_mbps || 100)
          }
        end
      )

    can_fit?(total_resources, target_host)
  end

  defp calculate_host_cost(_optimizer, _host) do
    10.0
  end

  defp analyze_machine_sizing(machine, lookback_days) do
    usage = get_historical_usage(machine, lookback_days)

    allocated = %{
      cpu_cores: machine.cpu_cores || 1,
      memory_gb: machine.memory_gb || 1
    }

    p95_cpu = percentile(usage.cpu_samples, 0.95)
    p95_memory = percentile(usage.memory_samples, 0.95)
    cpu_utilization = p95_cpu / allocated.cpu_cores
    memory_utilization = p95_memory / allocated.memory_gb

    recommendation =
      cond do
        cpu_utilization < 0.3 || memory_utilization < 0.3 ->
          :downsize

        cpu_utilization > 0.8 || memory_utilization > 0.8 ->
          :upsize

        true ->
          :optimal
      end

    %{
      machine_id: machine.id,
      recommendation: recommendation,
      current_allocation: allocated,
      p95_usage: %{cpu_cores: p95_cpu, memory_gb: p95_memory},
      utilization: %{cpu: cpu_utilization, memory: memory_utilization},
      potential_savings_usd: calculate_sizing_savings(recommendation, machine)
    }
  end

  defp get_historical_usage(_machine, _lookback_days) do
    %{
      cpu_samples: [0.5, 0.6, 0.4, 0.7],
      memory_samples: [0.6, 0.7, 0.5, 0.8]
    }
  end

  defp calculate_sizing_savings(recommendation, _machine) do
    case recommendation do
      :downsize -> 5.0
      :upsize -> -10.0
      :optimal -> 0.0
    end
  end

  defp forecast_costs(machine_costs) do
    current_total = Enum.sum(Enum.map(machine_costs, & &1.cost_per_hour))
    growth_rate = 0.05

    %{
      next_month: current_total * 24 * 30 * (1 + growth_rate),
      next_quarter: current_total * 24 * 90 * (1 + growth_rate * 3),
      next_year: current_total * 24 * 365 * (1 + growth_rate * 12)
    }
  end

  defp generate_cost_reduction_recommendations(overage, _options) do
    [
      %{
        action: "Consolidate underutilized hosts",
        estimated_savings: overage * 0.3,
        complexity: :medium
      },
      %{
        action: "Right-size overprovisioned machines",
        estimated_savings: overage * 0.4,
        complexity: :low
      },
      %{
        action: "Migrate to cheaper regions",
        estimated_savings: overage * 0.2,
        complexity: :high
      },
      %{
        action: "Enable spot instances where applicable",
        estimated_savings: overage * 0.5,
        complexity: :medium
      }
    ]
  end

  defp find_candidate_hosts(_resources, _options) do
    [
      %{
        id: "host-1",
        region: "lax",
        total_resources: %{cpu_cores: 16, memory_gb: 64, disk_gb: 1000, network_mbps: 1000},
        available_resources: %{cpu_cores: 8, memory_gb: 32, disk_gb: 500, network_mbps: 500}
      }
    ]
  end

  defp provision_new_host(_optimizer, _resources) do
    {:ok,
     %{
       id: "host-new-#{:rand.uniform(1000)}",
       region: "lax",
       total_resources: %{cpu_cores: 16, memory_gb: 64, disk_gb: 1000, network_mbps: 1000},
       available_resources: %{cpu_cores: 16, memory_gb: 64, disk_gb: 1000, network_mbps: 1000}
     }}
  end

  defp build_optimizer(options) do
    %__MODULE__{
      bin_packing_algorithm: options[:algorithm] || :best_fit,
      resource_prices: %{
        cpu_per_core_per_hour: 0.05,
        memory_per_gb_per_hour: 0.01,
        disk_per_gb_per_hour: 0.0001,
        network_per_mbps_per_hour: 0.0001
      },
      budget_constraints: options[:budget_limit],
      consolidation_mode: options[:prefer_consolidation] || true,
      spot_instance_enabled: options[:allow_spot] || false
    }
  end

  defp percentile(values, p) do
    if Enum.empty?(values) do
      0.0
    else
      sorted = Enum.sort(values)
      index = trunc(p * length(sorted))
      Enum.at(sorted, min(index, length(sorted) - 1), 0.0)
    end
  end
end
