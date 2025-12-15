defmodule Orchestrator.Placement.Scheduler do
  use GenServer
  require Logger
  alias Orchestrator.{Repo, Machines.Machine}
  alias Orchestrator.Placement.{ComplianceRules, CostModel, LatencyMatrix}
  import Ecto.Query

  @type machine_requirements :: %{
          cpu_cores: number(),
          memory_gb: number(),
          disk_gb: number(),
          traffic_sources: list(String.t()),
          compliance: map(),
          optimization_goal: atom(),
          constraints: map()
        }
  @type placement_result :: %{
          region: String.t(),
          score: float(),
          reasoning: String.t(),
          resource_allocation: map(),
          estimated_cost_monthly: Decimal.t(),
          expected_latency_ms: float()
        }
  @default_weights %{
    resource: 0.25,
    latency: 0.35,
    cost: 0.25,
    compliance: 0.15
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec schedule_machine(machine_requirements(), keyword()) ::
          {:ok, placement_result()} | {:error, term()}
  def schedule_machine(requirements, opts \\ []) do
    GenServer.call(__MODULE__, {:schedule_machine, requirements, opts}, 30_000)
  end

  @spec schedule_batch(list(machine_requirements()), keyword()) ::
          {:ok, list(placement_result())} | {:error, term()}
  def schedule_batch(requirements_list, opts \\ []) do
    GenServer.call(__MODULE__, {:schedule_batch, requirements_list, opts}, 60_000)
  end

  @spec reoptimize_placements(keyword()) :: {:ok, list(map())} | {:error, term()}
  def reoptimize_placements(opts \\ []) do
    GenServer.call(__MODULE__, {:reoptimize, opts}, 60_000)
  end

  @spec get_capacity_report() :: map()
  def get_capacity_report do
    GenServer.call(__MODULE__, :get_capacity_report)
  end

  @spec can_place?(String.t(), machine_requirements()) :: boolean()
  def can_place?(region, requirements) do
    GenServer.call(__MODULE__, {:can_place, region, requirements})
  end

  @impl true
  def init(opts) do
    regions = Keyword.get(opts, :regions, default_regions())
    capacity_tracking = initialize_capacity_tracking(regions)
    latency_matrix = LatencyMatrix.load()
    cost_models = CostModel.load_all()
    compliance_rules = ComplianceRules.load()

    state = %{
      capacity_tracking: capacity_tracking,
      latency_matrix: latency_matrix,
      cost_models: cost_models,
      compliance_rules: compliance_rules,
      placement_history: [],
      weights: Keyword.get(opts, :weights, @default_weights)
    }

    Logger.debug("Placement Scheduler started",
      regions: length(regions),
      latency_matrix_size: map_size(latency_matrix)
    )

    schedule_capacity_refresh()
    {:ok, state}
  end

  @impl true
  def handle_call({:schedule_machine, requirements, opts}, _from, state) do
    opts = if is_map(opts), do: Enum.to_list(opts), else: opts

    Logger.debug("Scheduling machine placement", requirements: sanitize_for_log(requirements))
    result = perform_scheduling(requirements, opts, state)

    case result do
      {:ok, placement} ->
        dry_run? = Keyword.get(opts, :dry_run, false)

        new_state =
          if dry_run? do
            state
          else
            reserve_capacity(state, placement.region, requirements)
          end

        new_state = add_to_placement_history(new_state, placement)
        {:reply, {:ok, placement}, new_state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:schedule_batch, requirements_list, opts}, _from, state) do
    opts = if is_map(opts), do: Enum.to_list(opts), else: opts

    Logger.debug("Batch scheduling #{length(requirements_list)} machines")
    result = perform_batch_scheduling(requirements_list, opts, state)

    case result do
      {:ok, placements} ->
        dry_run? = Keyword.get(opts, :dry_run, false)

        new_state =
          if dry_run? do
            state
          else
            Enum.reduce(placements, state, fn placement, acc_state ->
              requirements = Enum.at(requirements_list, placement.index)
              reserve_capacity(acc_state, placement.region, requirements)
            end)
          end

        {:reply, {:ok, placements}, new_state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reoptimize, opts}, _from, state) do
    Logger.debug("Re-optimizing machine placements")
    result = analyze_reoptimization_opportunities(state, opts)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:get_capacity_report, _from, state) do
    report = generate_capacity_report(state.capacity_tracking)
    {:reply, report, state}
  end

  @impl true
  def handle_call({:can_place, region, requirements}, _from, state) do
    capacity = Map.get(state.capacity_tracking, region)

    can_place? =
      if capacity do
        has_sufficient_resources?(capacity, requirements)
      else
        false
      end

    {:reply, can_place?, state}
  end

  @impl true
  def handle_info(:refresh_capacity, state) do
    Logger.debug("Refreshing region capacity data")
    refreshed_capacity = refresh_capacity_from_db(state.capacity_tracking)
    new_state = %{state | capacity_tracking: refreshed_capacity}
    schedule_capacity_refresh()
    {:noreply, new_state}
  end

  defp perform_scheduling(requirements, opts, state) do
    opts = if is_map(opts), do: Enum.to_list(opts), else: opts
    strategy = Keyword.get(opts, :strategy, :balanced)
    candidate_regions = Keyword.get(opts, :candidate_regions)

    compliant_regions =
      filter_by_compliance(
        candidate_regions || Map.keys(state.capacity_tracking),
        requirements,
        state.compliance_rules
      )

    capable_regions =
      Enum.filter(compliant_regions, fn region ->
        capacity = Map.get(state.capacity_tracking, region)
        capacity && has_sufficient_resources?(capacity, requirements)
      end)

    if Enum.empty?(capable_regions) do
      {:error, :no_suitable_region}
    else
      scored_regions =
        Enum.map(capable_regions, fn region ->
          score = calculate_placement_score(region, requirements, state, strategy)

          %{
            region: region,
            score: score.composite,
            reasoning: score.reasoning,
            resource_allocation: calculate_resource_allocation(region, requirements, state),
            estimated_cost_monthly:
              calculate_monthly_cost(region, requirements, state.cost_models),
            expected_latency_ms:
              calculate_expected_latency(region, requirements, state.latency_matrix)
          }
        end)

      best_placement = Enum.max_by(scored_regions, & &1.score)

      Logger.debug("Selected placement",
        region: best_placement.region,
        score: Float.round(best_placement.score, 3)
      )

      {:ok, best_placement}
    end
  end

  defp perform_batch_scheduling(requirements_list, opts, state) do
    placements =
      requirements_list
      |> Enum.with_index()
      |> Enum.reduce({[], state.capacity_tracking}, fn {requirements, idx},
                                                       {acc_placements, temp_capacity} ->
        temp_state = %{state | capacity_tracking: temp_capacity}

        case perform_scheduling(requirements, opts, temp_state) do
          {:ok, placement} ->
            placement_with_idx = Map.put(placement, :index, idx)
            updated_capacity = deduct_capacity(temp_capacity, placement.region, requirements)
            {[placement_with_idx | acc_placements], updated_capacity}

          {:error, _reason} ->
            {acc_placements, temp_capacity}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    {:ok, placements}
  end

  defp analyze_reoptimization_opportunities(state, _opts) do
    current_machines = Repo.all(from(m in Machine, where: m.status == "running"))

    recommendations =
      current_machines
      |> Enum.group_by(& &1.region)
      |> Enum.flat_map(fn {region, machines} ->
        capacity = Map.get(state.capacity_tracking, region)

        if capacity && capacity.utilization > 0.9 do
          Enum.map(machines, fn machine ->
            requirements = extract_machine_requirements(machine)

            case perform_scheduling(
                   requirements,
                   [candidate_regions: alternative_regions(region)],
                   state
                 ) do
              {:ok, alternative_placement} ->
                cost_savings =
                  calculate_cost_difference(
                    region,
                    alternative_placement.region,
                    requirements,
                    state.cost_models
                  )

                latency_change =
                  calculate_latency_difference(
                    region,
                    alternative_placement.region,
                    requirements,
                    state.latency_matrix
                  )

                if Decimal.compare(cost_savings, Decimal.new(0)) == :gt || latency_change < 0 do
                  %{
                    machine_id: machine.id,
                    current_region: region,
                    target_region: alternative_placement.region,
                    cost_savings_monthly: cost_savings,
                    latency_improvement_ms: -latency_change,
                    priority: calculate_migration_priority(cost_savings, latency_change)
                  }
                else
                  nil
                end

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
        else
          []
        end
      end)
      |> Enum.sort_by(& &1.priority, :desc)

    recommendations
  end

  defp calculate_placement_score(region, requirements, state, strategy) do
    weights = adjust_weights_for_strategy(state.weights, strategy)
    resource_score = score_resource_availability(region, requirements, state.capacity_tracking)
    latency_score = score_latency(region, requirements, state.latency_matrix)
    cost_score = score_cost(region, requirements, state.cost_models)
    compliance_score = score_compliance(region, requirements, state.compliance_rules)

    composite =
      weights.resource * resource_score +
        weights.latency * latency_score +
        weights.cost * cost_score +
        weights.compliance * compliance_score

    reasoning =
      build_reasoning(region, resource_score, latency_score, cost_score, compliance_score)

    %{
      composite: composite,
      resource: resource_score,
      latency: latency_score,
      cost: cost_score,
      compliance: compliance_score,
      reasoning: reasoning
    }
  end

  defp adjust_weights_for_strategy(weights, :cost) do
    %{weights | cost: 0.6, latency: 0.2, resource: 0.15, compliance: 0.05}
  end

  defp adjust_weights_for_strategy(weights, :latency) do
    %{weights | latency: 0.6, resource: 0.2, cost: 0.15, compliance: 0.05}
  end

  defp adjust_weights_for_strategy(weights, :compliance) do
    %{weights | compliance: 0.5, resource: 0.2, latency: 0.2, cost: 0.1}
  end

  defp adjust_weights_for_strategy(weights, :balanced), do: weights

  defp score_resource_availability(region, requirements, capacity_tracking) do
    capacity = Map.get(capacity_tracking, region)

    if capacity do
      cpu_required = Map.get(requirements, :cpu_cores) || Map.get(requirements, :cpu) || 0
      total_cpu_after = capacity.used_cpu_cores + cpu_required
      total_mem_after = capacity.used_memory_gb + requirements.memory_gb
      total_disk_after = capacity.used_disk_gb + requirements.disk_gb
      cpu_util = total_cpu_after / capacity.total_cpu_cores
      mem_util = total_mem_after / capacity.total_memory_gb
      disk_util = total_disk_after / capacity.total_disk_gb
      optimal_util = 0.65
      cpu_score = 1.0 - abs(cpu_util - optimal_util) / optimal_util
      mem_score = 1.0 - abs(mem_util - optimal_util) / optimal_util
      disk_score = 1.0 - abs(disk_util - optimal_util) / optimal_util
      avg_score = (cpu_score + mem_score + disk_score) / 3.0
      max(0.0, min(1.0, avg_score))
    else
      0.0
    end
  end

  defp score_latency(region, requirements, latency_matrix) do
    traffic_sources = Map.get(requirements, :traffic_sources, [])

    if Enum.empty?(traffic_sources) do
      1.0
    else
      latencies =
        Enum.map(traffic_sources, fn source ->
          LatencyMatrix.get_latency(latency_matrix, source, region) || 100.0
        end)

      avg_latency = Enum.sum(latencies) / length(latencies)
      max(0.0, min(1.0, 1.0 - avg_latency / 200.0))
    end
  end

  defp score_cost(region, requirements, cost_models) do
    cost_model = Map.get(cost_models, region)

    if cost_model do
      cpu_required = Map.get(requirements, :cpu_cores) || Map.get(requirements, :cpu) || 0

      monthly_cost =
        CostModel.calculate_monthly_cost(
          cost_model,
          cpu_required,
          requirements.memory_gb,
          requirements.disk_gb
        )

      max_cost = Decimal.new(500)

      normalized =
        Decimal.div(monthly_cost, max_cost)
        |> Decimal.to_float()

      max(0.0, min(1.0, 1.0 - normalized))
    else
      0.5
    end
  end

  defp score_compliance(region, requirements, compliance_rules) do
    compliance = Map.get(requirements, :compliance, %{})
    all_satisfied = ComplianceRules.check_compliance(compliance_rules, region, compliance)
    if all_satisfied, do: 1.0, else: 0.0
  end

  defp build_reasoning(_region, resource_score, latency_score, cost_score, compliance_score) do
    scores = [
      {"resource", resource_score},
      {"latency", latency_score},
      {"cost", cost_score},
      {"compliance", compliance_score}
    ]

    top_factors =
      scores
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(2)
      |> Enum.map(&elem(&1, 0))

    "Best #{Enum.join(top_factors, " and ")}"
  end

  defp initialize_capacity_tracking(regions) do
    Map.new(regions, fn region ->
      {region,
       %{
         total_cpu_cores: 1000,
         total_memory_gb: 4000,
         total_disk_gb: 20000,
         used_cpu_cores: 0,
         used_memory_gb: 0,
         used_disk_gb: 0,
         utilization: 0.0,
         last_updated: DateTime.utc_now()
       }}
    end)
  end

  defp refresh_capacity_from_db(capacity_tracking) do
    query = """
    SELECT
      region,
      SUM(CAST(metadata->>'cpu_cores' AS INTEGER)) as used_cpu,
      SUM(CAST(metadata->>'memory_gb' AS INTEGER)) as used_memory,
      SUM(CAST(metadata->>'disk_gb' AS INTEGER)) as used_disk
    FROM machines
    WHERE status IN ('running', 'starting')
    GROUP BY region
    """

    case Repo.query(query, []) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, capacity_tracking, fn [region, used_cpu, used_mem, used_disk], acc ->
          update_in(acc, [region], fn capacity ->
            if capacity do
              cpu_cores = used_cpu || 0
              memory_gb = used_mem || 0
              disk_gb = used_disk || 0

              utilization =
                (cpu_cores / capacity.total_cpu_cores +
                   memory_gb / capacity.total_memory_gb +
                   disk_gb / capacity.total_disk_gb) / 3.0

              %{
                capacity
                | used_cpu_cores: cpu_cores,
                  used_memory_gb: memory_gb,
                  used_disk_gb: disk_gb,
                  utilization: utilization,
                  last_updated: DateTime.utc_now()
              }
            else
              capacity
            end
          end)
        end)

      _ ->
        capacity_tracking
    end
  end

  defp has_sufficient_resources?(capacity, requirements) do
    available_cpu = capacity.total_cpu_cores - capacity.used_cpu_cores
    available_memory = capacity.total_memory_gb - capacity.used_memory_gb
    available_disk = capacity.total_disk_gb - capacity.used_disk_gb

    req_cpu = Map.get(requirements, :cpu_cores) || Map.get(requirements, :cpu) || 0

    req_memory =
      Map.get(requirements, :memory_gb) || (Map.get(requirements, :memory_mb) || 0) / 1024

    req_disk = Map.get(requirements, :disk_gb) || (Map.get(requirements, :disk_mb) || 0) / 1024

    available_cpu >= req_cpu &&
      available_memory >= req_memory &&
      available_disk >= req_disk
  end

  defp reserve_capacity(state, region, requirements) do
    req_cpu = Map.get(requirements, :cpu_cores) || Map.get(requirements, :cpu) || 0

    req_memory =
      Map.get(requirements, :memory_gb) || (Map.get(requirements, :memory_mb) || 0) / 1024

    req_disk = Map.get(requirements, :disk_gb) || (Map.get(requirements, :disk_mb) || 0) / 1024

    update_in(state, [:capacity_tracking, region], fn capacity ->
      if capacity do
        %{
          capacity
          | used_cpu_cores: capacity.used_cpu_cores + req_cpu,
            used_memory_gb: capacity.used_memory_gb + req_memory,
            used_disk_gb: capacity.used_disk_gb + req_disk
        }
      else
        capacity
      end
    end)
  end

  defp deduct_capacity(capacity_tracking, region, requirements) do
    req_cpu = Map.get(requirements, :cpu_cores) || Map.get(requirements, :cpu) || 0

    req_memory =
      Map.get(requirements, :memory_gb) || (Map.get(requirements, :memory_mb) || 0) / 1024

    req_disk = Map.get(requirements, :disk_gb) || (Map.get(requirements, :disk_mb) || 0) / 1024

    update_in(capacity_tracking, [region], fn capacity ->
      if capacity do
        %{
          capacity
          | used_cpu_cores: capacity.used_cpu_cores + req_cpu,
            used_memory_gb: capacity.used_memory_gb + req_memory,
            used_disk_gb: capacity.used_disk_gb + req_disk
        }
      else
        capacity
      end
    end)
  end

  defp generate_capacity_report(capacity_tracking) do
    regions =
      Enum.map(capacity_tracking, fn {region, capacity} ->
        %{
          region: region,
          cpu_utilization: capacity.used_cpu_cores / capacity.total_cpu_cores * 100,
          memory_utilization: capacity.used_memory_gb / capacity.total_memory_gb * 100,
          disk_utilization: capacity.used_disk_gb / capacity.total_disk_gb * 100,
          overall_utilization: capacity.utilization * 100,
          available_cpu_cores: capacity.total_cpu_cores - capacity.used_cpu_cores,
          available_memory_gb: capacity.total_memory_gb - capacity.used_memory_gb,
          available_disk_gb: capacity.total_disk_gb - capacity.used_disk_gb
        }
      end)
      |> Enum.sort_by(& &1.overall_utilization, :desc)

    %{
      regions: regions,
      total_regions: length(regions),
      avg_utilization:
        Enum.sum(Enum.map(regions, & &1.overall_utilization)) / max(1, length(regions)),
      high_utilization_regions: Enum.count(regions, &(&1.overall_utilization > 80)),
      timestamp: DateTime.utc_now()
    }
  end

  defp filter_by_compliance(regions, requirements, compliance_rules) do
    compliance = Map.get(requirements, :compliance, %{})

    Enum.filter(regions, fn region ->
      ComplianceRules.check_compliance(compliance_rules, region, compliance)
    end)
  end

  defp calculate_resource_allocation(region, requirements, state) do
    capacity = Map.get(state.capacity_tracking, region)
    cpu_required = Map.get(requirements, :cpu_cores) || Map.get(requirements, :cpu) || 0

    %{
      cpu_cores: cpu_required,
      memory_gb: requirements.memory_gb,
      disk_gb: requirements.disk_gb,
      region_cpu_utilization: (capacity.used_cpu_cores + cpu_required) / capacity.total_cpu_cores,
      region_memory_utilization:
        (capacity.used_memory_gb + requirements.memory_gb) / capacity.total_memory_gb
    }
  end

  defp calculate_monthly_cost(region, requirements, cost_models) do
    cost_model = Map.get(cost_models, region)

    if cost_model do
      cpu_required = Map.get(requirements, :cpu_cores) || Map.get(requirements, :cpu) || 0

      CostModel.calculate_monthly_cost(
        cost_model,
        cpu_required,
        requirements.memory_gb,
        requirements.disk_gb
      )
    else
      Decimal.new(0)
    end
  end

  defp calculate_expected_latency(region, requirements, latency_matrix) do
    traffic_sources = Map.get(requirements, :traffic_sources, [])

    if Enum.empty?(traffic_sources) do
      0.0
    else
      latencies =
        Enum.map(traffic_sources, fn source ->
          LatencyMatrix.get_latency(latency_matrix, source, region) || 0.0
        end)

      Enum.sum(latencies) / length(latencies)
    end
  end

  defp extract_machine_requirements(machine) do
    metadata = machine.metadata || %{}

    %{
      cpu_cores: Map.get(metadata, "cpu_cores", 2),
      memory_gb: Map.get(metadata, "memory_gb", 4),
      disk_gb: Map.get(metadata, "disk_gb", 50),
      traffic_sources: Map.get(metadata, "traffic_sources", []),
      compliance: Map.get(metadata, "compliance", %{})
    }
  end

  defp alternative_regions(current_region) do
    default_regions() -- [current_region]
  end

  defp calculate_cost_difference(from_region, to_region, requirements, cost_models) do
    from_cost = calculate_monthly_cost(from_region, requirements, cost_models)
    to_cost = calculate_monthly_cost(to_region, requirements, cost_models)
    Decimal.sub(from_cost, to_cost)
  end

  defp calculate_latency_difference(from_region, to_region, requirements, latency_matrix) do
    from_latency = calculate_expected_latency(from_region, requirements, latency_matrix)
    to_latency = calculate_expected_latency(to_region, requirements, latency_matrix)
    from_latency - to_latency
  end

  defp calculate_migration_priority(cost_savings, latency_improvement) do
    cost_score = Decimal.to_float(cost_savings) / 10.0
    latency_score = latency_improvement / 10.0
    cost_score + latency_score
  end

  defp add_to_placement_history(state, placement) do
    history_entry = %{
      region: placement.region,
      score: placement.score,
      timestamp: DateTime.utc_now()
    }

    history =
      [history_entry | state.placement_history]
      |> Enum.take(1000)

    %{state | placement_history: history}
  end

  defp default_regions do
    ["us-east-1", "us-west-1", "eu-west-1", "ap-south-1"]
  end

  defp sanitize_for_log(requirements) do
    Map.take(requirements, [:cpu_cores, :memory_gb, :disk_gb, :optimization_goal])
  end

  defp schedule_capacity_refresh do
    Process.send_after(self(), :refresh_capacity, 60_000)
  end
end
