defmodule Orchestrator.PlacementScheduler do
  require Logger

  @type strategy :: :first_fit | :best_fit | :worst_fit
  @type region :: String.t()
  @type resources :: %{cpu_cores: float(), memory_mb: integer(), disk_mb: integer()}
  @type placement_result :: {:ok, region()} | {:error, :no_suitable_region}

  @spec find_placement(resources(), keyword()) :: placement_result()
  def find_placement(resources, opts \\ []) do
    start_time = System.monotonic_time(:microsecond)

    strategy = Keyword.get(opts, :strategy, :first_fit)
    candidate_regions = Keyword.get(opts, :regions, get_all_regions())
    constraints = Keyword.get(opts, :constraints, [])
    prefer_region = Keyword.get(opts, :prefer_region)

    unless strategy in [:first_fit, :best_fit, :worst_fit] do
      raise ArgumentError, "Invalid strategy: #{inspect(strategy)}"
    end

    region_capacities =
      candidate_regions
      |> Enum.map(fn region ->
        capacity = get_region_capacity(region)
        {region, capacity}
      end)
      |> Enum.reject(fn {_region, capacity} -> is_nil(capacity) end)

    valid_regions =
      apply_constraints(region_capacities, resources, constraints)

    result =
      case strategy do
        :first_fit ->
          first_fit_placement(valid_regions, resources, prefer_region)

        :best_fit ->
          best_fit_placement(valid_regions, resources, prefer_region)

        :worst_fit ->
          worst_fit_placement(valid_regions, resources, prefer_region)
      end

    duration_us = System.monotonic_time(:microsecond) - start_time

    emit_placement_telemetry(strategy, result, duration_us, resources)

    case result do
      {:ok, region} ->
        Logger.info("Placement decision",
          strategy: strategy,
          region: region,
          cpu_cores: resources.cpu_cores,
          memory_mb: resources.memory_mb,
          disk_mb: resources.disk_mb,
          duration_us: duration_us
        )

      {:error, :no_suitable_region} ->
        Logger.warning("No suitable region found",
          strategy: strategy,
          requested_cpu: resources.cpu_cores,
          requested_memory: resources.memory_mb,
          requested_disk: resources.disk_mb,
          candidates: length(candidate_regions),
          valid_after_constraints: length(valid_regions)
        )
    end

    result
  end

  @spec evaluate_placement(resources(), keyword()) ::
          {:ok, [region()]} | {:error, :no_suitable_region}
  def evaluate_placement(resources, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :first_fit)
    candidate_regions = Keyword.get(opts, :regions, get_all_regions())
    constraints = Keyword.get(opts, :constraints, [])

    region_capacities =
      candidate_regions
      |> Enum.map(fn region ->
        capacity = get_region_capacity(region)
        {region, capacity}
      end)
      |> Enum.reject(fn {_region, capacity} -> is_nil(capacity) end)

    valid_regions = apply_constraints(region_capacities, resources, constraints)

    ranked_regions =
      case strategy do
        :first_fit ->
          Enum.filter(valid_regions, fn {_region, capacity} ->
            can_fit?(capacity, resources)
          end)
          |> Enum.map(fn {region, _capacity} -> region end)

        :best_fit ->
          valid_regions
          |> Enum.filter(fn {_region, capacity} -> can_fit?(capacity, resources) end)
          |> Enum.sort_by(
            fn {_region, capacity} ->
              remaining_after_allocation(capacity, resources)
            end,
            :asc
          )
          |> Enum.map(fn {region, _capacity} -> region end)

        :worst_fit ->
          valid_regions
          |> Enum.filter(fn {_region, capacity} -> can_fit?(capacity, resources) end)
          |> Enum.sort_by(
            fn {_region, capacity} ->
              remaining_after_allocation(capacity, resources)
            end,
            :desc
          )
          |> Enum.map(fn {region, _capacity} -> region end)
      end

    if Enum.empty?(ranked_regions) do
      {:error, :no_suitable_region}
    else
      {:ok, ranked_regions}
    end
  end

  @spec get_region_utilization(region()) :: %{cpu: float(), memory: float(), disk: float()} | nil
  def get_region_utilization(region) do
    case get_region_capacity(region) do
      nil ->
        nil

      capacity ->
        %{
          cpu: capacity.utilization_pct.cpu,
          memory: capacity.utilization_pct.memory,
          disk: capacity.utilization_pct.disk
        }
    end
  end

  defp first_fit_placement(regions, resources, prefer_region) do
    preferred_result =
      if prefer_region do
        case Enum.find(regions, fn {region, _cap} -> region == prefer_region end) do
          {^prefer_region, capacity} ->
            if can_fit?(capacity, resources), do: {:ok, prefer_region}, else: nil

          _ ->
            nil
        end
      else
        nil
      end

    case preferred_result do
      {:ok, _region} = result ->
        result

      nil ->
        case Enum.find(regions, fn {_region, capacity} -> can_fit?(capacity, resources) end) do
          {region, _capacity} -> {:ok, region}
          nil -> {:error, :no_suitable_region}
        end
    end
  end

  defp best_fit_placement(regions, resources, prefer_region) do
    suitable_regions =
      regions
      |> Enum.filter(fn {_region, capacity} -> can_fit?(capacity, resources) end)
      |> Enum.map(fn {region, capacity} ->
        remaining = remaining_after_allocation(capacity, resources)
        {region, remaining}
      end)

    if Enum.empty?(suitable_regions) do
      {:error, :no_suitable_region}
    else
      preferred_result =
        if prefer_region do
          case Enum.find(suitable_regions, fn {region, _rem} -> region == prefer_region end) do
            {^prefer_region, pref_remaining} ->
              {_best_region, best_remaining} =
                Enum.min_by(suitable_regions, fn {_r, rem} -> rem end)

              if pref_remaining <= best_remaining * 1.2 do
                {:ok, prefer_region}
              else
                nil
              end

            _ ->
              nil
          end
        else
          nil
        end

      case preferred_result do
        {:ok, _region} = result ->
          result

        nil ->
          {best_region, _remaining} = Enum.min_by(suitable_regions, fn {_region, rem} -> rem end)
          {:ok, best_region}
      end
    end
  end

  defp worst_fit_placement(regions, resources, prefer_region) do
    suitable_regions =
      regions
      |> Enum.filter(fn {_region, capacity} -> can_fit?(capacity, resources) end)
      |> Enum.map(fn {region, capacity} ->
        remaining = remaining_after_allocation(capacity, resources)
        {region, remaining}
      end)

    if Enum.empty?(suitable_regions) do
      {:error, :no_suitable_region}
    else
      preferred_result =
        if prefer_region do
          case Enum.find(suitable_regions, fn {region, _rem} -> region == prefer_region end) do
            {^prefer_region, pref_remaining} ->
              {_worst_region, worst_remaining} =
                Enum.max_by(suitable_regions, fn {_r, rem} -> rem end)

              if pref_remaining >= worst_remaining * 0.8 do
                {:ok, prefer_region}
              else
                nil
              end

            _ ->
              nil
          end
        else
          nil
        end

      case preferred_result do
        {:ok, _region} = result ->
          result

        nil ->
          {worst_region, _remaining} = Enum.max_by(suitable_regions, fn {_region, rem} -> rem end)
          {:ok, worst_region}
      end
    end
  end

  defp can_fit?(capacity, resources) do
    capacity.available.cpu_cores >= resources.cpu_cores and
      capacity.available.memory_mb >= resources.memory_mb and
      capacity.available.disk_mb >= resources.disk_mb
  end

  defp remaining_after_allocation(capacity, resources) do
    cpu_remaining = capacity.available.cpu_cores - resources.cpu_cores
    memory_remaining = capacity.available.memory_mb - resources.memory_mb
    disk_remaining = capacity.available.disk_mb - resources.disk_mb

    cpu_pct = cpu_remaining / max(capacity.total.cpu_cores, 0.01)
    memory_pct = memory_remaining / max(capacity.total.memory_mb, 1)
    disk_pct = disk_remaining / max(capacity.total.disk_mb, 1)

    score = cpu_pct * 0.4 + memory_pct * 0.4 + disk_pct * 0.2
    Float.round(score, 4)
  end

  defp apply_constraints(regions, _resources, []) do
    regions
  end

  defp apply_constraints(regions, resources, constraints) do
    Enum.reduce(constraints, regions, fn constraint, acc ->
      apply_single_constraint(acc, resources, constraint)
    end)
  end

  defp apply_single_constraint(regions, _resources, {:exclude_regions, excluded}) do
    Enum.reject(regions, fn {region, _capacity} ->
      region in excluded
    end)
  end

  defp apply_single_constraint(regions, _resources, {:only_regions, allowed}) do
    Enum.filter(regions, fn {region, _capacity} ->
      region in allowed
    end)
  end

  defp apply_single_constraint(regions, _resources, {:min_cpu_utilization, min_pct}) do
    Enum.filter(regions, fn {_region, capacity} ->
      capacity.utilization_pct.cpu >= min_pct
    end)
  end

  defp apply_single_constraint(regions, _resources, {:max_cpu_utilization, max_pct}) do
    Enum.filter(regions, fn {_region, capacity} ->
      capacity.utilization_pct.cpu <= max_pct
    end)
  end

  defp apply_single_constraint(regions, _resources, _unknown_constraint) do
    regions
  end

  defp get_all_regions do
    ["us-east-1", "us-west-2", "eu-west-1", "ap-south-1", "ap-northeast-1"]
  end

  defp get_region_capacity(_region) do
    Orchestrator.ResourceManager.get_capacity()
  end

  defp emit_placement_telemetry(strategy, result, duration_us, resources) do
    status =
      case result do
        {:ok, _} -> :success
        {:error, _} -> :failed
      end

    :telemetry.execute(
      [:orchestrator, :placement_scheduler, :placement],
      %{duration_us: duration_us},
      %{
        strategy: strategy,
        status: status,
        cpu_cores: resources.cpu_cores,
        memory_mb: resources.memory_mb,
        disk_mb: resources.disk_mb
      }
    )
  end
end
