defmodule Orchestrator.Replication.VectorClockTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Replication.VectorClock, as: VC

  describe "init/1" do
    test "creates vector clock with local node counter at 0" do
      vc = VC.init(:node1)

      assert vc.clock == %{node1: 0}
      assert vc.local_node == :node1
    end
  end

  describe "increment/2" do
    test "increments counter for specified node" do
      vc = VC.init(:node1)
      vc = VC.increment(vc, :node1)

      assert vc.clock == %{node1: 1}

      vc = VC.increment(vc, :node1)
      assert vc.clock == %{node1: 2}
    end

    test "creates entry for new node" do
      vc = VC.init(:node1)
      vc = VC.increment(vc, :node2)

      assert vc.clock == %{node1: 0, node2: 1}
    end
  end

  describe "merge/2" do
    test "element-wise maximum of counters" do
      vc1 = %VC{clock: %{node1: 3, node2: 1, node3: 5}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 2, node2: 4, node3: 3}, local_node: :node2}

      merged = VC.merge(vc1, vc2)

      assert merged.clock == %{node1: 3, node2: 4, node3: 5}
    end

    test "handles nodes present in only one clock" do
      vc1 = %VC{clock: %{node1: 5}, local_node: :node1}
      vc2 = %VC{clock: %{node2: 3}, local_node: :node2}

      merged = VC.merge(vc1, vc2)

      assert merged.clock == %{node1: 5, node2: 3}
    end

    test "commutative property" do
      vc1 = %VC{clock: %{node1: 3, node2: 1}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 2, node2: 4}, local_node: :node2}

      merged_ab = VC.merge(vc1, vc2)
      merged_ba = VC.merge(vc2, vc1)

      assert merged_ab.clock == merged_ba.clock
    end

    test "idempotent property" do
      vc = %VC{clock: %{node1: 5, node2: 3}, local_node: :node1}

      merged = VC.merge(vc, vc)

      assert merged.clock == vc.clock
    end

    test "monotonic property" do
      vc1 = %VC{clock: %{node1: 3, node2: 1}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 5, node2: 2}, local_node: :node2}

      merged = VC.merge(vc1, vc2)

      assert VC.dominates?(merged, vc1)
      assert VC.dominates?(merged, vc2)
    end
  end

  describe "compare/2" do
    test "less than: all counters <= and at least one <" do
      vc1 = %VC{clock: %{node1: 1, node2: 2}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 1, node2: 3}, local_node: :node2}

      assert VC.compare(vc1, vc2) == :lt
      assert VC.compare(vc2, vc1) == :gt
    end

    test "greater than" do
      vc1 = %VC{clock: %{node1: 5, node2: 3}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 4, node2: 2}, local_node: :node2}

      assert VC.compare(vc1, vc2) == :gt
      assert VC.compare(vc2, vc1) == :lt
    end

    test "equal: all counters equal" do
      vc1 = %VC{clock: %{node1: 5, node2: 3}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 5, node2: 3}, local_node: :node2}

      assert VC.compare(vc1, vc2) == :eq
    end

    test "concurrent: incomparable" do
      vc1 = %VC{clock: %{node1: 3, node2: 1}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 1, node2: 3}, local_node: :node2}

      assert VC.compare(vc1, vc2) == :concurrent
      assert VC.compare(vc2, vc1) == :concurrent
    end

    test "concurrent even with different nodes" do
      vc1 = %VC{clock: %{node1: 5}, local_node: :node1}
      vc2 = %VC{clock: %{node2: 3}, local_node: :node2}

      assert VC.compare(vc1, vc2) == :concurrent
    end
  end

  describe "dominates?/2" do
    test "true when all counters >= and at least one >" do
      vc1 = %VC{clock: %{node1: 5, node2: 3}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 4, node2: 2}, local_node: :node2}

      assert VC.dominates?(vc1, vc2)
      refute VC.dominates?(vc2, vc1)
    end

    test "true when equal" do
      vc = %VC{clock: %{node1: 5, node2: 3}, local_node: :node1}

      assert VC.dominates?(vc, vc)
    end

    test "false when concurrent" do
      vc1 = %VC{clock: %{node1: 3, node2: 1}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 1, node2: 3}, local_node: :node2}

      refute VC.dominates?(vc1, vc2)
      refute VC.dominates?(vc2, vc1)
    end
  end

  describe "concurrent?/2" do
    test "true when incomparable" do
      vc1 = %VC{clock: %{node1: 3, node2: 1}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 1, node2: 3}, local_node: :node2}

      assert VC.concurrent?(vc1, vc2)
    end

    test "false when one dominates" do
      vc1 = %VC{clock: %{node1: 5, node2: 3}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 4, node2: 2}, local_node: :node2}

      refute VC.concurrent?(vc1, vc2)
    end
  end

  describe "prune/2" do
    test "removes nodes not in active set" do
      vc = %VC{clock: %{node1: 5, node2: 3, node3: 7}, local_node: :node1}
      active_nodes = [:node1, :node3]

      pruned = VC.prune(vc, active_nodes)

      assert pruned.clock == %{node1: 5, node3: 7}
    end

    test "keeps all nodes if all active" do
      vc = %VC{clock: %{node1: 5, node2: 3}, local_node: :node1}
      active_nodes = [:node1, :node2]

      pruned = VC.prune(vc, active_nodes)

      assert pruned.clock == vc.clock
    end
  end

  describe "size/1" do
    test "returns number of tracked nodes" do
      vc = %VC{clock: %{node1: 5, node2: 3, node3: 7}, local_node: :node1}

      assert VC.size(vc) == 3
    end
  end

  describe "total_events/1" do
    test "sums all counters" do
      vc = %VC{clock: %{node1: 5, node2: 3, node3: 7}, local_node: :node1}

      assert VC.total_events(vc) == 15
    end
  end

  describe "Causality tracking scenario" do
    test "simple happened-before chain" do
      vc_a = VC.init(:node1)
      vc_a = VC.increment(vc_a, :node1)

      vc_b = VC.init(:node2)
      vc_b = VC.merge(vc_b, vc_a)
      vc_b = VC.increment(vc_b, :node2)

      vc_c = VC.init(:node3)
      vc_c = VC.merge(vc_c, vc_b)
      vc_c = VC.increment(vc_c, :node3)

      assert VC.compare(vc_a, vc_b) == :lt
      assert VC.compare(vc_b, vc_c) == :lt
      assert VC.compare(vc_a, vc_c) == :lt
    end

    test "concurrent events" do
      vc_a = VC.init(:node1)
      vc_a = VC.increment(vc_a, :node1)

      vc_b = VC.init(:node2)
      vc_b = VC.increment(vc_b, :node2)

      assert VC.concurrent?(vc_a, vc_b)
    end

    test "network partition scenario" do
      vc1 = %VC{clock: %{node1: 5, node2: 5, node3: 5}, local_node: :node1}
      vc2 = %VC{clock: %{node1: 5, node2: 5, node3: 5}, local_node: :node2}
      vc3 = %VC{clock: %{node1: 5, node2: 5, node3: 5}, local_node: :node3}

      vc1 = VC.increment(vc1, :node1)
      vc2 = VC.increment(vc2, :node2)
      vc1 = VC.merge(vc1, vc2)
      vc2 = VC.merge(vc2, vc1)

      vc3 = VC.increment(vc3, :node3)

      assert VC.concurrent?(vc1, vc3)

      vc1 = VC.merge(vc1, vc3)
      vc2 = VC.merge(vc2, vc3)
      vc3 = VC.merge(vc3, vc1)

      assert vc1.clock == vc2.clock
      assert vc2.clock == vc3.clock
    end
  end
end
