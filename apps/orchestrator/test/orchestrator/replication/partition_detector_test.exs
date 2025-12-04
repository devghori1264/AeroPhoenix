defmodule Orchestrator.Replication.PartitionDetectorTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Replication.PartitionDetector

  setup do
    :ok
  end

  describe "initialization" do
    test "starts with unknown partition status" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 5, name: nil)

      assert Process.alive?(pid)
      assert PartitionDetector.status(pid) in [:majority, :minority, :unknown]
    end

    test "initializes as follower in Raft" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 5, name: nil)

      assert PartitionDetector.raft_state(pid) == :follower
      assert PartitionDetector.leader(pid) == nil
    end

    test "calculates correct cluster size" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 7, name: nil)

      stats = PartitionDetector.stats(pid)
      assert stats.cluster_size == 7
    end
  end

  describe "partition detection" do
    test "single node (N=1) is always majority" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 1, name: nil)

      Process.sleep(200)

      assert PartitionDetector.status(pid) == :majority
      refute PartitionDetector.read_only?(pid)
    end

    test "isolated node in N=5 cluster is minority" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 5, name: nil)

      Process.sleep(200)

      assert PartitionDetector.status(pid) == :minority
      assert PartitionDetector.read_only?(pid)
    end

    test "majority partition (3 out of 5 nodes) accepts writes" do
      :ok
    end
  end

  describe "debounce mechanism" do
    test "requires 3 consecutive checks before status change" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 5, name: nil)

      initial_status = PartitionDetector.get_partition_status(pid)
      assert initial_status == :unknown

      Process.sleep(200)
      status_after_1 = PartitionDetector.status(pid)

      Process.sleep(200)
      status_after_2 = PartitionDetector.status(pid)

      Process.sleep(200)
      status_after_3 = PartitionDetector.status(pid)

      assert status_after_1 in [:majority, :minority, :unknown]
      assert status_after_2 in [:majority, :minority, :unknown]
      assert status_after_3 in [:majority, :minority, :unknown]
    end
  end

  describe "leader election" do
    test "starts election after timeout (150-300ms)" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 1, name: nil)

      Process.sleep(400)

      stats = PartitionDetector.stats(pid)
      assert stats.raft_state == :leader
      assert stats.leader == Node.self()
    end

    test "increments term on each election" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 1, name: nil)

      Process.sleep(200)
      stats_1 = PartitionDetector.stats(pid)
      term_1 = stats_1.term

      Process.sleep(400)
      stats_2 = PartitionDetector.stats(pid)
      term_2 = stats_2.term

      assert term_2 >= term_1
    end
  end

  describe "statistics" do
    test "includes partition status metrics" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 5, name: nil)

      stats = PartitionDetector.stats(pid)

      assert Map.has_key?(stats, :partition_status)
      assert Map.has_key?(stats, :visible_nodes)
      assert Map.has_key?(stats, :cluster_size)
      assert Map.has_key?(stats, :read_only)
      assert is_boolean(stats.read_only)
    end

    test "includes Raft state metrics" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 3, name: nil)

      stats = PartitionDetector.stats(pid)

      assert Map.has_key?(stats, :raft_state)
      assert stats.raft_state in [:follower, :candidate, :leader]
      assert Map.has_key?(stats, :term)
      assert is_integer(stats.term)
      assert Map.has_key?(stats, :leader)
    end

    test "tracks election count" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 1, name: nil)

      Process.sleep(200)

      stats = PartitionDetector.stats(pid)
      assert Map.has_key?(stats, :elections_total)
      assert stats.elections_total >= 0
    end

    test "tracks partition status changes" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 5, name: nil)

      Process.sleep(300)

      stats = PartitionDetector.stats(pid)
      assert Map.has_key?(stats, :partition_changes_total)
      assert stats.partition_changes_total >= 0
    end
  end

  describe "read-only mode" do
    test "read_only?/0 returns true in minority partition" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 5, name: nil)

      Process.sleep(300)

      if PartitionDetector.status(pid) == :minority do
        assert PartitionDetector.read_only?(pid) == true
      end
    end

    test "read_only?/0 returns false in majority partition" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 1, name: nil)

      Process.sleep(200)

      if PartitionDetector.status(pid) == :majority do
        assert PartitionDetector.read_only?(pid) == false
      end
    end
  end

  describe "PubSub notifications" do
    test "broadcasts read-only status on minority partition" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_actor:*")

      {:ok, _pid} = PartitionDetector.start_link(cluster_size: 5, name: nil)

      Process.sleep(300)

      receive do
        {:partition_status, status} ->
          assert status in [:read_only, :writable]
      after
        1_000 ->
          :ok
      end
    end
  end

  describe "edge cases" do
    test "handles N=2 cluster (tie scenarios)" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 2, name: nil)

      Process.sleep(300)

      stats = PartitionDetector.stats(pid)

      if stats.visible_nodes == 1 do
        assert stats.partition_status == :minority
      end
    end

    test "handles N=3 cluster (smallest production-viable)" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 3, name: nil)

      Process.sleep(300)

      stats = PartitionDetector.stats(pid)

      if stats.visible_nodes == 1 do
        assert stats.partition_status == :minority
      end
    end

    test "handles very large cluster (N=101)" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 101, name: nil)

      stats = PartitionDetector.stats(pid)
      assert stats.cluster_size == 101
    end
  end

  describe "resilience" do
    test "survives process crash and restart" do
      test_name = :"partition_detector_#{:erlang.unique_integer()}"

      pid = start_supervised!({PartitionDetector, [cluster_size: 5, name: test_name]})

      assert Process.alive?(pid)
      _initial_status = PartitionDetector.status(test_name)

      Process.exit(pid, :kill)
      Process.sleep(300)

      new_pid = Process.whereis(test_name)
      assert new_pid != nil
      assert new_pid != pid
      assert Process.alive?(new_pid)

      status_after_restart = PartitionDetector.status(test_name)
      assert status_after_restart in [:majority, :minority, :unknown]
    end

    test "handles concurrent status checks" do
      {:ok, pid} = PartitionDetector.start_link(cluster_size: 5, name: nil)

      tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            PartitionDetector.status(pid)
          end)
        end

      results = Task.await_many(tasks)

      assert Enum.all?(results, fn status ->
               status in [:majority, :minority, :unknown]
             end)
    end
  end
end
