defmodule Orchestrator.Replication.GossipProtocolTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Replication.{
    GossipProtocol,
    CRDTState,
    VectorClock,
    HybridLogicalClock
  }

  setup do
    start_supervised!({Registry, keys: :unique, name: Orchestrator.Registry})

    start_supervised!({Phoenix.PubSub, name: Orchestrator.PubSub})

    :ok
  end

  describe "initialization" do
    test "starts gossip protocol with initial state" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state,
          gossip_interval_ms: 60_000,
          fanout: 3
        )

      assert Process.alive?(pid)

      stats = GossipProtocol.stats(pid)
      assert stats.machine_id == machine_id
      assert stats.gossip_round == 0
      assert stats.deltas_sent == 0
    end

    test "registers with unique name" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid1} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      {:error, {:already_started, ^pid1}} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )
    end
  end

  describe "gossip round" do
    test "performs gossip round when triggered" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state,
          gossip_interval_ms: 60_000
        )

      initial_stats = GossipProtocol.stats(pid)
      assert initial_stats.gossip_round == 0

      GossipProtocol.trigger_gossip(pid)

      Process.sleep(100)

      updated_stats = GossipProtocol.stats(pid)
      assert updated_stats.gossip_round == 1
    end

    test "builds Merkle tree during gossip round" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      GossipProtocol.trigger_gossip(pid)
      Process.sleep(100)

      stats = GossipProtocol.stats(pid)
      assert stats.merkle_tree_stats != nil
      assert stats.merkle_tree_stats.bucket_count == 256
    end
  end

  describe "delta application" do
    test "applies local delta and broadcasts" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      {:ok, delta, updated_crdt} = CRDTState.increment_counter(crdt_state, :transitions, 1)
      GossipProtocol.apply_local_delta(pid, delta, updated_crdt)

      Process.sleep(100)

      stats = GossipProtocol.stats(pid)
      assert stats.deltas_sent == 1
    end

    test "deduplicates received deltas" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      {:ok, delta, _updated_crdt} = CRDTState.increment_counter(crdt_state, :transitions, 1)

      send(pid, {:gossip_delta, delta})
      Process.sleep(50)

      send(pid, {:gossip_delta, delta})
      Process.sleep(50)

      stats = GossipProtocol.stats(pid)
      assert stats.deltas_received == 1
      assert stats.seen_deltas_count == 1
    end
  end

  describe "failure detection integration" do
    @tag :skip
    test "records heartbeats from peers" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state,
          heartbeat_interval_ms: 1_000
        )

      peer_node = :peer@localhost
      send(pid, {:heartbeat, peer_node})

      Process.sleep(100)

      stats = GossipProtocol.stats(pid)
      assert stats.total_peers >= 1
    end

    @tag :skip
    test "detects failed peers via phi accrual" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state,
          heartbeat_interval_ms: 100
        )

      peer_node = :peer@localhost

      for _ <- 1..10 do
        send(pid, {:heartbeat, peer_node})
        Process.sleep(110)
      end

      stats_healthy = GossipProtocol.stats(pid)
      assert stats_healthy.active_peers >= 1

      Process.sleep(2_000)

      stats_failed = GossipProtocol.stats(pid)
      assert stats_failed.failed_peers >= 1
    end
  end

  describe "adaptive fanout" do
    test "uses default fanout for small clusters" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state,
          fanout: 3
        )

      GossipProtocol.trigger_gossip(pid)
      Process.sleep(100)

      stats = GossipProtocol.stats(pid)
      assert stats.gossip_round == 1
    end
  end

  describe "metrics and stats" do
    test "tracks gossip rounds" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      for _i <- 1..5 do
        GossipProtocol.trigger_gossip(pid)
        Process.sleep(50)
      end

      stats = GossipProtocol.stats(pid)
      assert stats.gossip_round == 5
    end

    test "tracks deltas sent and received" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      for i <- 1..3 do
        {:ok, delta, updated_crdt} =
          CRDTState.increment_counter(crdt_state, :transitions, i)

        GossipProtocol.apply_local_delta(pid, delta, updated_crdt)
        Process.sleep(50)
      end

      stats = GossipProtocol.stats(pid)
      assert stats.deltas_sent == 3
    end

    test "includes Merkle tree stats" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      GossipProtocol.trigger_gossip(pid)
      Process.sleep(100)

      stats = GossipProtocol.stats(pid)
      assert stats.merkle_tree_stats != nil
      assert is_integer(stats.merkle_tree_stats.entry_count)
      assert is_integer(stats.merkle_tree_stats.bucket_count)
    end
  end

  describe "edge cases" do
    test "handles empty peer list gracefully" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      GossipProtocol.trigger_gossip(pid)
      Process.sleep(100)

      stats = GossipProtocol.stats(pid)
      assert stats.gossip_round == 1
      assert stats.active_peers == 0
    end

    test "handles concurrent delta applications" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            {:ok, delta, updated_crdt} =
              CRDTState.increment_counter(crdt_state, :transitions, i)

            GossipProtocol.apply_local_delta(pid, delta, updated_crdt)
          end)
        end

      Task.await_many(tasks)
      Process.sleep(200)

      stats = GossipProtocol.stats(pid)
      assert stats.deltas_sent == 10
    end

    test "recovers from malformed delta" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      malformed_delta = %{invalid: "data"}
      send(pid, {:gossip_delta, malformed_delta})

      Process.sleep(100)

      assert Process.alive?(pid)

      stats = GossipProtocol.stats(pid)
      assert stats.deltas_received == 0
    end
  end

  describe "PubSub integration" do
    test "broadcasts deltas via PubSub" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "gossip:#{machine_id}")

      {:ok, delta, updated_crdt} = CRDTState.increment_counter(crdt_state, :transitions, 1)
      GossipProtocol.apply_local_delta(pid, delta, updated_crdt)

      assert_receive {:gossip_delta, ^delta}, 1000
    end

    test "receives deltas from other processes via PubSub" do
      machine_id = "test-machine-#{:rand.uniform(10000)}"
      crdt_state = CRDTState.new(machine_id)

      {:ok, pid} =
        GossipProtocol.start_link(
          machine_id: machine_id,
          crdt_state: crdt_state
        )

      {:ok, delta, _updated_crdt} = CRDTState.increment_counter(crdt_state, :transitions, 1)

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "gossip:#{machine_id}",
        {:gossip_delta, delta}
      )

      Process.sleep(100)

      stats = GossipProtocol.stats(pid)
      assert stats.deltas_received == 1
    end
  end
end
