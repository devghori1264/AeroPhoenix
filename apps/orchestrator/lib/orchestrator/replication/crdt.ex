defmodule Orchestrator.Replication.CRDT do
  defmodule GCounter do
    defstruct counts: %{}
    def new, do: %__MODULE__{}

    def increment(counter, node_id, amount \\ 1) do
      new_count = Map.get(counter.counts, node_id, 0) + amount
      %{counter | counts: Map.put(counter.counts, node_id, new_count)}
    end

    def value(counter) do
      counter.counts |> Map.values() |> Enum.sum()
    end

    def merge(counter1, counter2) do
      merged_counts =
        Map.merge(counter1.counts, counter2.counts, fn _k, v1, v2 ->
          max(v1, v2)
        end)

      %__MODULE__{counts: merged_counts}
    end
  end

  defmodule PNCounter do
    defstruct positive: %GCounter{}, negative: %GCounter{}
    def new, do: %__MODULE__{}

    def increment(counter, node_id, amount \\ 1) do
      %{counter | positive: GCounter.increment(counter.positive, node_id, amount)}
    end

    def decrement(counter, node_id, amount \\ 1) do
      %{counter | negative: GCounter.increment(counter.negative, node_id, amount)}
    end

    def value(counter) do
      GCounter.value(counter.positive) - GCounter.value(counter.negative)
    end

    def merge(counter1, counter2) do
      %__MODULE__{
        positive: GCounter.merge(counter1.positive, counter2.positive),
        negative: GCounter.merge(counter1.negative, counter2.negative)
      }
    end
  end

  defmodule LWWRegister do
    defstruct value: nil, timestamp: 0, node_id: nil
    def new, do: %__MODULE__{}

    def set(register, value, node_id) do
      timestamp = System.system_time(:microsecond)
      %{register | value: value, timestamp: timestamp, node_id: node_id}
    end

    def value(register), do: register.value

    def merge(reg1, reg2) do
      cond do
        reg1.timestamp > reg2.timestamp -> reg1
        reg1.timestamp < reg2.timestamp -> reg2
        reg1.node_id > reg2.node_id -> reg1
        true -> reg2
      end
    end
  end

  defmodule ORSet do
    defstruct elements: %{}, tombstones: MapSet.new()
    def new, do: %__MODULE__{}

    def add(set, element, node_id) do
      unique_tag = {element, node_id, System.system_time(:microsecond)}
      new_elements = Map.update(set.elements, element, [unique_tag], &[unique_tag | &1])
      %{set | elements: new_elements}
    end

    def remove(set, element) do
      tags = Map.get(set.elements, element, [])
      new_tombstones = Enum.reduce(tags, set.tombstones, &MapSet.put(&2, &1))
      new_elements = Map.delete(set.elements, element)
      %{set | elements: new_elements, tombstones: new_tombstones}
    end

    def contains?(set, element) do
      Map.has_key?(set.elements, element)
    end

    def to_list(set) do
      Map.keys(set.elements)
    end

    def merge(set1, set2) do
      merged_elements =
        Map.merge(set1.elements, set2.elements, fn _k, tags1, tags2 ->
          Enum.uniq(tags1 ++ tags2)
        end)

      merged_tombstones = MapSet.union(set1.tombstones, set2.tombstones)

      cleaned_elements =
        Enum.reduce(merged_elements, %{}, fn {element, tags}, acc ->
          live_tags = Enum.reject(tags, &MapSet.member?(merged_tombstones, &1))

          if live_tags == [] do
            acc
          else
            Map.put(acc, element, live_tags)
          end
        end)

      %__MODULE__{elements: cleaned_elements, tombstones: merged_tombstones}
    end
  end

  defmodule VectorClock do
    defstruct clocks: %{}
    def new, do: %__MODULE__{}

    def increment(vc, node_id) do
      new_clock = Map.update(vc.clocks, node_id, 1, &(&1 + 1))
      %{vc | clocks: new_clock}
    end

    def compare(vc1, vc2) do
      all_nodes = (Map.keys(vc1.clocks) ++ Map.keys(vc2.clocks)) |> Enum.uniq()

      {less, greater} =
        Enum.reduce(all_nodes, {false, false}, fn node, {less_acc, greater_acc} ->
          v1 = Map.get(vc1.clocks, node, 0)
          v2 = Map.get(vc2.clocks, node, 0)
          {less_acc || v1 < v2, greater_acc || v1 > v2}
        end)

      cond do
        less and greater -> :concurrent
        less -> :before
        greater -> :after
        true -> :equal
      end
    end

    def merge(vc1, vc2) do
      all_nodes = (Map.keys(vc1.clocks) ++ Map.keys(vc2.clocks)) |> Enum.uniq()

      merged_clocks =
        Enum.reduce(all_nodes, %{}, fn node, acc ->
          v1 = Map.get(vc1.clocks, node, 0)
          v2 = Map.get(vc2.clocks, node, 0)
          Map.put(acc, node, max(v1, v2))
        end)

      %__MODULE__{clocks: merged_clocks}
    end

    def get(vc, node_id) do
      Map.get(vc.clocks, node_id, 0)
    end
  end
end
