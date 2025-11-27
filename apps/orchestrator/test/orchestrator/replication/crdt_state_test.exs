defmodule Orchestrator.Replication.CRDTStateTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Replication.{CRDTState, HybridLogicalClock, VectorClock}

  describe "init/1" do
    test "creates empty CRDT state with initialized clocks" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      assert crdt.machine_id == "m1"
      assert crdt.node_id == :node1
      assert crdt.counters == %{}
      assert crdt.registers == %{}
      assert crdt.sets == %{}
      assert is_struct(crdt.hlc, HybridLogicalClock)
      assert is_struct(crdt.vector_clock, VectorClock)
    end
  end

  describe "increment_counter/3 (GCounter)" do
    test "increments counter and generates delta" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, delta1} = CRDTState.increment_counter(crdt, :transitions, 1)
      assert delta1.type == :counter_increment
      assert delta1.key == :transitions
      assert delta1.value == 1

      {:ok, crdt} = CRDTState.merge_delta(crdt, delta1)
      assert CRDTState.get_counter(crdt, :transitions) == 1

      {:ok, delta2} = CRDTState.increment_counter(crdt, :transitions, 5)
      {:ok, crdt} = CRDTState.merge_delta(crdt, delta2)
      assert CRDTState.get_counter(crdt, :transitions) == 6
    end

    test "handles concurrent increments from different nodes" do
      crdt1 = CRDTState.init(machine_id: "m1", node_id: :node1)
      crdt2 = CRDTState.init(machine_id: "m1", node_id: :node2)

      {:ok, delta1} = CRDTState.increment_counter(crdt1, :cpu_count, 3)
      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta1)

      {:ok, delta2} = CRDTState.increment_counter(crdt2, :cpu_count, 5)
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta2)

      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta2)
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta1)

      assert CRDTState.get_counter(crdt1, :cpu_count) == 8
      assert CRDTState.get_counter(crdt2, :cpu_count) == 8
    end

    test "rejects negative increments (GCounter monotonicity)" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      assert {:error, :negative_increment} =
               CRDTState.increment_counter(crdt, :count, -5)
    end
  end

  describe "set_register/3 (LWWRegister)" do
    test "sets register value with HLC timestamp" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, delta} = CRDTState.set_register(crdt, :region, "iad")
      assert delta.type == :register_set
      assert delta.key == :region
      assert delta.value == "iad"
      assert is_struct(delta.timestamp, HybridLogicalClock)

      {:ok, crdt} = CRDTState.merge_delta(crdt, delta)
      assert CRDTState.get_register(crdt, :region) == "iad"
    end

    test "last-write-wins resolution based on HLC" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, delta1} = CRDTState.set_register(crdt, :region, "iad")
      {:ok, crdt} = CRDTState.merge_delta(crdt, delta1)

      Process.sleep(10)

      {:ok, delta2} = CRDTState.set_register(crdt, :region, "ord")
      {:ok, crdt} = CRDTState.merge_delta(crdt, delta2)

      assert CRDTState.get_register(crdt, :region) == "ord"

      {:ok, crdt} = CRDTState.merge_delta(crdt, delta1)
      assert CRDTState.get_register(crdt, :region) == "ord"
    end

    test "handles concurrent writes with HLC tie-breaking" do
      crdt1 = CRDTState.init(machine_id: "m1", node_id: :node1)
      crdt2 = CRDTState.init(machine_id: "m1", node_id: :node2)

      {:ok, delta1} = CRDTState.set_register(crdt1, :config, "value1")
      {:ok, delta2} = CRDTState.set_register(crdt2, :config, "value2")

      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta1)
      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta2)

      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta2)
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta1)

      value1 = CRDTState.get_register(crdt1, :config)
      value2 = CRDTState.get_register(crdt2, :config)
      assert value1 == value2
    end
  end

  describe "add_to_set/3 and remove_from_set/3 (ORSet)" do
    test "adds element to set with unique tag" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, delta} = CRDTState.add_to_set(crdt, :capabilities, "ssh")
      assert delta.type == :set_add
      assert delta.key == :capabilities
      assert delta.element == "ssh"
      assert is_binary(delta.tag)

      {:ok, crdt} = CRDTState.merge_delta(crdt, delta)
      assert CRDTState.get_set(crdt, :capabilities) == MapSet.new(["ssh"])
    end

    test "removes element from set with tombstone" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, add_delta} = CRDTState.add_to_set(crdt, :tags, "production")
      {:ok, crdt} = CRDTState.merge_delta(crdt, add_delta)

      assert CRDTState.get_set(crdt, :tags) == MapSet.new(["production"])

      {:ok, remove_delta} = CRDTState.remove_from_set(crdt, :tags, "production")
      {:ok, crdt} = CRDTState.merge_delta(crdt, remove_delta)

      assert CRDTState.get_set(crdt, :tags) == MapSet.new([])
    end

    test "add-wins semantics for concurrent add/remove" do
      crdt1 = CRDTState.init(machine_id: "m1", node_id: :node1)
      crdt2 = CRDTState.init(machine_id: "m1", node_id: :node2)

      {:ok, add_delta} = CRDTState.add_to_set(crdt1, :ports, "http")
      {:ok, crdt1} = CRDTState.merge_delta(crdt1, add_delta)

      {:ok, remove_delta} = CRDTState.remove_from_set(crdt2, :ports, "http")
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, remove_delta)

      {:ok, crdt1} = CRDTState.merge_delta(crdt1, remove_delta)
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, add_delta)

      assert CRDTState.get_set(crdt1, :ports) == MapSet.new(["http"])
      assert CRDTState.get_set(crdt2, :ports) == MapSet.new(["http"])
    end

    test "handles multiple concurrent adds of same element" do
      crdt1 = CRDTState.init(machine_id: "m1", node_id: :node1)
      crdt2 = CRDTState.init(machine_id: "m1", node_id: :node2)

      {:ok, delta1} = CRDTState.add_to_set(crdt1, :roles, "admin")
      {:ok, delta2} = CRDTState.add_to_set(crdt2, :roles, "admin")

      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta1)
      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta2)

      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta2)
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta1)

      assert CRDTState.get_set(crdt1, :roles) == MapSet.new(["admin"])
      assert CRDTState.get_set(crdt2, :roles) == MapSet.new(["admin"])
    end
  end

  describe "merge_delta/2" do
    test "updates vector clock on merge" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      initial_vc = crdt.vector_clock
      {:ok, delta} = CRDTState.increment_counter(crdt, :count, 1)
      {:ok, crdt} = CRDTState.merge_delta(crdt, delta)

      assert VectorClock.compare(crdt.vector_clock, initial_vc) == :gt
    end

    test "idempotent - merging same delta twice is safe" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, delta} = CRDTState.increment_counter(crdt, :count, 5)

      {:ok, crdt1} = CRDTState.merge_delta(crdt, delta)
      {:ok, crdt2} = CRDTState.merge_delta(crdt1, delta)

      assert CRDTState.get_counter(crdt1, :count) ==
               CRDTState.get_counter(crdt2, :count)
    end

    test "commutative - merge order doesn't matter" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, delta1} = CRDTState.increment_counter(crdt, :a, 3)
      {:ok, delta2} = CRDTState.increment_counter(crdt, :b, 5)

      {:ok, crdt1} = CRDTState.merge_delta(crdt, delta1)
      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta2)

      {:ok, crdt2} = CRDTState.merge_delta(crdt, delta2)
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta1)

      assert CRDTState.get_counter(crdt1, :a) == CRDTState.get_counter(crdt2, :a)
      assert CRDTState.get_counter(crdt1, :b) == CRDTState.get_counter(crdt2, :b)
    end
  end

  describe "to_map/1" do
    test "materializes current state snapshot" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, delta1} = CRDTState.increment_counter(crdt, :count, 10)
      {:ok, crdt} = CRDTState.merge_delta(crdt, delta1)

      {:ok, delta2} = CRDTState.set_register(crdt, :region, "iad")
      {:ok, crdt} = CRDTState.merge_delta(crdt, delta2)

      {:ok, delta3} = CRDTState.add_to_set(crdt, :tags, "prod")
      {:ok, crdt} = CRDTState.merge_delta(crdt, delta3)

      snapshot = CRDTState.to_map(crdt)

      assert snapshot.counters == %{count: 10}
      assert snapshot.registers == %{region: "iad"}
      assert snapshot.sets == %{tags: MapSet.new(["prod"])}
    end
  end

  describe "compress_delta/1" do
    test "compresses delta with zlib" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, delta} = CRDTState.set_register(crdt, :large_value, String.duplicate("x", 1000))

      {:ok, compressed} = CRDTState.compress_delta(delta)
      uncompressed = :erlang.term_to_binary(delta)

      assert byte_size(compressed) < byte_size(uncompressed)
    end

    test "decompress restores original delta" do
      crdt = CRDTState.init(machine_id: "m1", node_id: :node1)

      {:ok, original_delta} = CRDTState.increment_counter(crdt, :count, 42)

      {:ok, compressed} = CRDTState.compress_delta(original_delta)
      {:ok, decompressed_delta} = CRDTState.decompress_delta(compressed)

      assert decompressed_delta.type == original_delta.type
      assert decompressed_delta.key == original_delta.key
      assert decompressed_delta.value == original_delta.value
    end
  end

  describe "Network partition scenario" do
    test "nodes converge after partition heals" do
      crdt1 = CRDTState.init(machine_id: "m1", node_id: :node1)
      crdt2 = CRDTState.init(machine_id: "m1", node_id: :node2)
      crdt3 = CRDTState.init(machine_id: "m1", node_id: :node3)

      {:ok, delta1a} = CRDTState.increment_counter(crdt1, :requests, 100)
      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta1a)

      {:ok, delta2a} = CRDTState.increment_counter(crdt2, :requests, 200)
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta2a)

      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta2a)
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta1a)

      {:ok, delta3a} = CRDTState.increment_counter(crdt3, :requests, 50)
      {:ok, crdt3} = CRDTState.merge_delta(crdt3, delta3a)

      {:ok, crdt1} = CRDTState.merge_delta(crdt1, delta3a)
      {:ok, crdt2} = CRDTState.merge_delta(crdt2, delta3a)
      {:ok, crdt3} = CRDTState.merge_delta(crdt3, delta1a)
      {:ok, crdt3} = CRDTState.merge_delta(crdt3, delta2a)

      final_value = CRDTState.get_counter(crdt1, :requests)
      assert CRDTState.get_counter(crdt2, :requests) == final_value
      assert CRDTState.get_counter(crdt3, :requests) == final_value
      assert final_value == 350
    end
  end
end
