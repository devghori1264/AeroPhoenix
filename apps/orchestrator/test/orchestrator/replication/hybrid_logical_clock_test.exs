defmodule Orchestrator.Replication.HybridLogicalClockTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Replication.HybridLogicalClock, as: HLC

  describe "init/1" do
    test "creates HLC with current physical time" do
      hlc = HLC.init()

      assert hlc.physical_time > 0
      assert hlc.logical_counter == 0
      assert hlc.node_id == Node.self()
    end

    test "accepts custom node_id" do
      hlc = HLC.init(node_id: :custom_node)
      assert hlc.node_id == :custom_node
    end
  end

  describe "tick/1" do
    test "advances physical time when wall clock moves forward" do
      hlc1 = HLC.init()
      Process.sleep(10)
      hlc2 = HLC.tick(hlc1)

      assert hlc2.physical_time > hlc1.physical_time
      assert hlc2.logical_counter == 0
    end

    test "increments logical counter in same millisecond" do
      hlc1 = HLC.init()
      hlc2 = HLC.tick(hlc1)

      if hlc2.physical_time == hlc1.physical_time do
        assert hlc2.logical_counter == hlc1.logical_counter + 1
      end
    end

    test "handles wall clock going backwards (NTP adjustment)" do
      hlc = %HLC{physical_time: 1000, logical_counter: 5, node_id: :node1}
      hlc_updated = HLC.tick(hlc)

      assert hlc_updated.physical_time >= hlc.physical_time
    end
  end

  describe "update/2" do
    test "updates with remote timestamp ahead of local" do
      now = System.system_time(:millisecond)
      local = %HLC{physical_time: now, logical_counter: 5, node_id: :node1}
      remote = %HLC{physical_time: now + 500, logical_counter: 3, node_id: :node2}

      updated = HLC.update(local, remote)

      assert updated.physical_time >= now + 500
      assert updated.logical_counter == 4
    end

    test "updates with local timestamp ahead of remote" do
      now = System.system_time(:millisecond)
      local = %HLC{physical_time: now + 500, logical_counter: 10, node_id: :node1}
      remote = %HLC{physical_time: now, logical_counter: 20, node_id: :node2}

      updated = HLC.update(local, remote)

      assert updated.physical_time >= now + 500
      assert updated.logical_counter == 11
    end

    test "updates with equal physical times" do
      now = System.system_time(:millisecond)
      local = %HLC{physical_time: now + 1000, logical_counter: 5, node_id: :node1}
      remote = %HLC{physical_time: now + 1000, logical_counter: 8, node_id: :node2}

      updated = HLC.update(local, remote)

      assert updated.physical_time >= now + 1000
      assert updated.logical_counter == 9
    end

    test "causality: updated HLC > both local and remote" do
      now = System.system_time(:millisecond)
      local = %HLC{physical_time: now, logical_counter: 5, node_id: :node1}
      remote = %HLC{physical_time: now + 50, logical_counter: 3, node_id: :node2}

      updated = HLC.update(local, remote)

      assert HLC.compare(updated, local) == :gt
      assert HLC.compare(updated, remote) == :gt
    end
  end

  describe "compare/2" do
    test "compares by physical time first" do
      hlc1 = %HLC{physical_time: 1000, logical_counter: 10, node_id: :node1}
      hlc2 = %HLC{physical_time: 2000, logical_counter: 5, node_id: :node2}

      assert HLC.compare(hlc1, hlc2) == :lt
      assert HLC.compare(hlc2, hlc1) == :gt
    end

    test "compares by logical counter when physical time equal" do
      hlc1 = %HLC{physical_time: 1000, logical_counter: 5, node_id: :node1}
      hlc2 = %HLC{physical_time: 1000, logical_counter: 10, node_id: :node2}

      assert HLC.compare(hlc1, hlc2) == :lt
      assert HLC.compare(hlc2, hlc1) == :gt
    end

    test "tie-breaks by node_id when both components equal" do
      hlc1 = %HLC{physical_time: 1000, logical_counter: 5, node_id: :node_a}
      hlc2 = %HLC{physical_time: 1000, logical_counter: 5, node_id: :node_b}

      result = HLC.compare(hlc1, hlc2)
      assert result in [:lt, :gt]
      assert HLC.compare(hlc2, hlc1) == if(result == :lt, do: :gt, else: :lt)
    end

    test "equal timestamps" do
      hlc1 = %HLC{physical_time: 1000, logical_counter: 5, node_id: :node1}
      hlc2 = %HLC{physical_time: 1000, logical_counter: 5, node_id: :node1}

      assert HLC.compare(hlc1, hlc2) == :eq
    end

    test "total ordering property" do
      hlc1 = HLC.init(node_id: :node1)
      hlc2 = HLC.tick(hlc1)
      hlc3 = HLC.tick(hlc2)

      assert HLC.compare(hlc1, hlc2) == :lt
      assert HLC.compare(hlc2, hlc3) == :lt
      assert HLC.compare(hlc1, hlc3) == :lt
    end
  end

  describe "to_timestamp/1 and from_timestamp/2" do
    test "round-trip conversion" do
      original = %HLC{physical_time: 1_700_000_000_000, logical_counter: 42, node_id: :node1}

      {pt, lc} = HLC.to_timestamp(original)
      restored = HLC.from_timestamp({pt, lc}, :node1)

      assert restored.physical_time == original.physical_time
      assert restored.logical_counter == original.logical_counter
      assert restored.node_id == original.node_id
    end
  end

  describe "time_diff_ms/2" do
    test "calculates time difference in milliseconds" do
      hlc1 = %HLC{physical_time: 1000, logical_counter: 0, node_id: :node1}
      hlc2 = %HLC{physical_time: 1500, logical_counter: 0, node_id: :node1}

      assert HLC.time_diff_ms(hlc2, hlc1) == 500
      assert HLC.time_diff_ms(hlc1, hlc2) == -500
    end
  end

  describe "Happened-before relationship" do
    test "sequential events maintain causality" do
      hlc_a = HLC.init(node_id: :node1)
      hlc_a = HLC.tick(hlc_a)

      hlc_b = HLC.init(node_id: :node2)
      hlc_b = HLC.update(hlc_b, hlc_a)
      hlc_b = HLC.tick(hlc_b)

      assert HLC.compare(hlc_a, hlc_b) == :lt
    end

    test "concurrent events on different nodes" do
      hlc1 = HLC.init(node_id: :node1)
      hlc2 = HLC.init(node_id: :node2)

      hlc1 = HLC.tick(hlc1)
      hlc2 = HLC.tick(hlc2)

      result = HLC.compare(hlc1, hlc2)
      assert result in [:lt, :gt]
    end
  end
end
