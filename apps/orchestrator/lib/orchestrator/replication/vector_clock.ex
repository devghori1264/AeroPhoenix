defmodule Orchestrator.Replication.VectorClock do
  require Logger

  @type node_id :: atom()
  @type t :: %__MODULE__{
          clock: %{node_id() => non_neg_integer()},
          local_node: node_id()
        }

  defstruct clock: %{}, local_node: nil
  @spec init(node_id()) :: t()
  def init(local_node) do
    %__MODULE__{
      clock: %{local_node => 0},
      local_node: local_node
    }
  end

  @spec increment(t(), node_id()) :: t()
  def increment(vc, node_id) do
    updated_clock = Map.update(vc.clock, node_id, 1, &(&1 + 1))
    %{vc | clock: updated_clock}
  end

  @spec merge(t(), t()) :: t()
  def merge(vc1, vc2) do
    all_nodes = MapSet.union(MapSet.new(Map.keys(vc1.clock)), MapSet.new(Map.keys(vc2.clock)))

    merged_clock =
      Enum.reduce(all_nodes, %{}, fn node, acc ->
        val1 = Map.get(vc1.clock, node, 0)
        val2 = Map.get(vc2.clock, node, 0)
        Map.put(acc, node, max(val1, val2))
      end)

    %{vc1 | clock: merged_clock}
  end

  @spec compare(t(), t()) :: :lt | :gt | :eq | :concurrent
  def compare(vc1, vc2) do
    all_nodes = MapSet.union(MapSet.new(Map.keys(vc1.clock)), MapSet.new(Map.keys(vc2.clock)))

    {less_than, greater_than, equal} =
      Enum.reduce(all_nodes, {false, false, true}, fn node, {lt, gt, eq} ->
        val1 = Map.get(vc1.clock, node, 0)
        val2 = Map.get(vc2.clock, node, 0)

        cond do
          val1 < val2 -> {true, gt, false}
          val1 > val2 -> {lt, true, false}
          true -> {lt, gt, eq}
        end
      end)

    cond do
      equal -> :eq
      less_than and not greater_than -> :lt
      greater_than and not less_than -> :gt
      true -> :concurrent
    end
  end

  @spec get(t(), node_id()) :: non_neg_integer()
  def get(vc, node_id) do
    Map.get(vc.clock, node_id, 0)
  end

  @spec set(t(), node_id(), non_neg_integer()) :: t()
  def set(vc, node_id, value) when value >= 0 do
    updated_clock = Map.put(vc.clock, node_id, value)
    %{vc | clock: updated_clock}
  end

  @spec dominates?(t(), t()) :: boolean()
  def dominates?(vc1, vc2) do
    compare(vc1, vc2) in [:gt, :eq]
  end

  @spec concurrent?(t(), t()) :: boolean()
  def concurrent?(vc1, vc2) do
    compare(vc1, vc2) == :concurrent
  end

  @spec prune(t(), [node_id()]) :: t()
  def prune(vc, active_nodes) do
    active_set = MapSet.new(active_nodes)

    pruned_clock =
      vc.clock
      |> Enum.filter(fn {node, _count} -> MapSet.member?(active_set, node) end)
      |> Map.new()

    pruned_count = map_size(vc.clock) - map_size(pruned_clock)

    if pruned_count > 0 do
      Logger.debug("Pruned #{pruned_count} nodes from vector clock",
        machine_id: inspect(vc.local_node)
      )
    end

    %{vc | clock: pruned_clock}
  end

  @spec to_map(t()) :: %{node_id() => non_neg_integer()}
  def to_map(vc) do
    vc.clock
  end

  @spec from_map(%{node_id() => non_neg_integer()}, node_id()) :: t()
  def from_map(map, local_node) when is_map(map) do
    %__MODULE__{
      clock: map,
      local_node: local_node
    }
  end

  @spec size(t()) :: non_neg_integer()
  def size(vc) do
    map_size(vc.clock)
  end

  @spec total_events(t()) :: non_neg_integer()
  def total_events(vc) do
    vc.clock |> Map.values() |> Enum.sum()
  end
end
