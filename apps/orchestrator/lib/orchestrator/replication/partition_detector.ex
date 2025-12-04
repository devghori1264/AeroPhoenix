defmodule Orchestrator.Replication.PartitionDetector do
  use GenServer
  require Logger

  @debounce_checks 3
  @election_timeout_min_ms 150
  @election_timeout_max_ms 300
  @heartbeat_interval_ms 50

  @type partition_status :: :majority | :minority | :unknown
  @type raft_state :: :follower | :candidate | :leader
  @type raft_term :: non_neg_integer()

  @type state :: %{
          node_id: atom(),
          cluster_size: pos_integer(),
          partition_status: partition_status(),
          debounce_count: non_neg_integer(),
          last_status: partition_status(),
          raft_state: raft_state(),
          term: raft_term(),
          leader: atom() | nil,
          voted_for: atom() | nil,
          votes_received: MapSet.t(),
          election_timeout_ms: pos_integer(),
          last_heartbeat_at: integer(),
          elections_total: non_neg_integer(),
          partition_changes_total: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(GenServer.server()) :: partition_status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @spec get_partition_status(GenServer.server()) :: partition_status()
  def get_partition_status(server \\ __MODULE__) do
    status(server)
  end

  @spec raft_state(GenServer.server()) :: raft_state()
  def raft_state(server \\ __MODULE__) do
    GenServer.call(server, :raft_state)
  end

  @spec leader(GenServer.server()) :: atom() | nil
  def leader(server \\ __MODULE__) do
    GenServer.call(server, :leader)
  end

  @spec read_only?(GenServer.server()) :: boolean()
  def read_only?(server \\ __MODULE__) do
    status(server) == :minority
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    cluster_size = Keyword.fetch!(opts, :cluster_size)
    node_id = Keyword.get(opts, :node_id, Node.self())

    initial_status = if cluster_size == 1, do: :majority, else: :unknown

    state = %{
      node_id: node_id,
      cluster_size: cluster_size,
      partition_status: initial_status,
      debounce_count: if(cluster_size == 1, do: 3, else: 0),
      last_status: initial_status,
      raft_state: :follower,
      term: 0,
      leader: nil,
      voted_for: nil,
      votes_received: MapSet.new(),
      election_timeout_ms: random_election_timeout(),
      last_heartbeat_at: System.monotonic_time(:millisecond),
      elections_total: 0,
      partition_changes_total: 0
    }

    :net_kernel.monitor_nodes(true, node_type: :all)

    Phoenix.PubSub.subscribe(Orchestrator.PubSub, "partition_detector")

    schedule_partition_check()

    schedule_election_timeout_check()

    Logger.info("PartitionDetector started",
      node_id: node_id,
      cluster_size: cluster_size
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.partition_status, state}
  end

  @impl true
  def handle_call(:raft_state, _from, state) do
    {:reply, state.raft_state, state}
  end

  @impl true
  def handle_call(:leader, _from, state) do
    {:reply, state.leader, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = compile_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:partition_check, state) do
    new_state = check_partition_status(state)
    schedule_partition_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:election_timeout_check, state) do
    new_state = check_election_timeout(state)
    schedule_election_timeout_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:heartbeat_tick, state) do
    if state.raft_state == :leader do
      broadcast_heartbeat(state)
      schedule_heartbeat()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, peer_node, _info}, state) do
    Logger.info("Peer node connected (partition may be healing)",
      peer: peer_node,
      current_status: state.partition_status
    )

    new_state = check_partition_status(state)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodedown, peer_node, _info}, state) do
    Logger.warning("Peer node disconnected (potential partition)",
      peer: peer_node,
      current_status: state.partition_status
    )

    new_state = check_partition_status(state)

    new_state =
      if state.leader == peer_node do
        Logger.info("Leader disconnected, starting election", term: state.term + 1)
        start_election(%{new_state | leader: nil})
      else
        new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:vote_request, from_node, candidate_term}, state) do
    new_state = handle_vote_request(from_node, candidate_term, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:vote_granted, from_node, term}, state) do
    new_state = handle_vote_granted(from_node, term, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:vote_result, _vote_id, _result}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:heartbeat, from_node, leader_term}, state) do
    new_state = handle_heartbeat(from_node, leader_term, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp check_partition_status(state) do
    visible_peers = Node.list()
    total_visible = length(visible_peers) + 1

    new_status =
      cond do
        total_visible > state.cluster_size / 2 -> :majority
        total_visible == state.cluster_size / 2 -> :minority
        true -> :minority
      end

    {debounced_status, debounce_count} =
      if new_status == state.last_status do
        count = state.debounce_count + 1

        if count >= @debounce_checks do
          {new_status, count}
        else
          {state.partition_status, count}
        end
      else
        {state.partition_status, 1}
      end

    status_changed = debounced_status != state.partition_status

    if status_changed do
      Logger.warning("Partition status changed",
        old_status: state.partition_status,
        new_status: debounced_status,
        visible_nodes: total_visible,
        cluster_size: state.cluster_size
      )

      :telemetry.execute(
        [:orchestrator, :partition, :status_changed],
        %{
          visible_nodes: total_visible,
          cluster_size: state.cluster_size
        },
        %{
          old_status: state.partition_status,
          new_status: debounced_status
        }
      )

      handle_partition_status_change(debounced_status, state)
    end

    %{
      state
      | partition_status: debounced_status,
        last_status: new_status,
        debounce_count: debounce_count,
        partition_changes_total:
          state.partition_changes_total + if(status_changed, do: 1, else: 0)
    }
  end

  defp handle_partition_status_change(:minority, state) do
    Logger.error("Entering READ-ONLY mode (minority partition)",
      cluster_size: state.cluster_size
    )

    Phoenix.PubSub.broadcast(
      Orchestrator.PubSub,
      "machine_actor:*",
      {:partition_status, :read_only}
    )

    if state.raft_state == :leader do
      %{state | raft_state: :follower, leader: nil}
    else
      state
    end
  end

  defp handle_partition_status_change(:majority, state) do
    Logger.info("Entering NORMAL mode (majority partition)")

    Phoenix.PubSub.broadcast(
      Orchestrator.PubSub,
      "machine_actor:*",
      {:partition_status, :writable}
    )

    if state.leader == nil and state.raft_state == :follower do
      start_election(state)
    else
      state
    end
  end

  defp start_election(state) do
    new_term = state.term + 1

    votes = MapSet.new([state.node_id])

    new_timeout = random_election_timeout()

    new_state = %{
      state
      | raft_state: :candidate,
        term: new_term,
        voted_for: state.node_id,
        votes_received: votes,
        election_timeout_ms: new_timeout,
        last_heartbeat_at: System.monotonic_time(:millisecond),
        elections_total: state.elections_total + 1
    }

    Logger.info("Starting election",
      term: new_term,
      election_timeout_ms: new_timeout
    )

    visible_nodes = length(Node.list()) + 1
    votes_needed = div(state.cluster_size, 2) + 1

    if MapSet.size(votes) >= votes_needed do
      Logger.info("Won election immediately (single-node or isolated)",
        votes: MapSet.size(votes),
        needed: votes_needed,
        cluster_size: state.cluster_size,
        visible_nodes: visible_nodes
      )

      become_leader(new_state)
    else
      request_votes(new_state)
      new_state
    end
  end

  defp request_votes(state) do
    peers = Node.list()

    Enum.each(peers, fn peer ->
      send({__MODULE__, peer}, {:vote_request, state.node_id, state.term})
    end)
  end

  defp handle_vote_request(from_node, candidate_term, state) do
    cond do
      candidate_term < state.term ->
        Logger.debug("Rejecting vote (stale term)",
          candidate: from_node,
          candidate_term: candidate_term,
          our_term: state.term
        )

        state

      candidate_term == state.term and state.voted_for != nil and
          state.voted_for != from_node ->
        Logger.debug("Rejecting vote (already voted)",
          candidate: from_node,
          voted_for: state.voted_for
        )

        state

      true ->
        Logger.info("Granting vote",
          candidate: from_node,
          term: candidate_term
        )

        send({__MODULE__, from_node}, {:vote_granted, state.node_id, candidate_term})

        %{
          state
          | term: candidate_term,
            voted_for: from_node,
            raft_state: :follower,
            leader: nil
        }
    end
  end

  defp handle_vote_granted(from_node, term, state) do
    cond do
      term < state.term ->
        state

      state.raft_state != :candidate ->
        state

      true ->
        new_votes = MapSet.put(state.votes_received, from_node)
        vote_count = MapSet.size(new_votes)

        Logger.debug("Received vote",
          from: from_node,
          votes: vote_count,
          needed: div(state.cluster_size, 2) + 1
        )

        if vote_count > state.cluster_size / 2 do
          become_leader(%{state | votes_received: new_votes})
        else
          %{state | votes_received: new_votes}
        end
    end
  end

  defp become_leader(state) do
    Logger.info("Elected as leader",
      term: state.term,
      votes: MapSet.size(state.votes_received)
    )

    schedule_heartbeat()

    %{
      state
      | raft_state: :leader,
        leader: state.node_id
    }
  end

  defp broadcast_heartbeat(state) do
    peers = Node.list()

    Enum.each(peers, fn peer ->
      send({__MODULE__, peer}, {:heartbeat, state.node_id, state.term})
    end)
  end

  defp handle_heartbeat(from_node, leader_term, state) do
    cond do
      leader_term < state.term ->
        state

      true ->
        new_state =
          if leader_term > state.term do
            %{state | term: leader_term, voted_for: nil}
          else
            state
          end

        new_state = %{
          new_state
          | last_heartbeat_at: System.monotonic_time(:millisecond),
            leader: from_node,
            raft_state: :follower
        }

        new_state
    end
  end

  defp check_election_timeout(state) do
    if state.raft_state == :leader do
      state
    else
      now = System.monotonic_time(:millisecond)
      time_since_heartbeat = now - state.last_heartbeat_at

      if time_since_heartbeat > state.election_timeout_ms do
        Logger.info("Election timeout exceeded, starting election",
          time_since_heartbeat: time_since_heartbeat,
          timeout: state.election_timeout_ms,
          current_state: state.raft_state
        )

        start_election(state)
      else
        state
      end
    end
  end

  defp random_election_timeout do
    @election_timeout_min_ms + :rand.uniform(@election_timeout_max_ms - @election_timeout_min_ms)
  end

  defp compile_stats(state) do
    visible_peers = Node.list()

    %{
      partition_status: state.partition_status,
      visible_nodes: length(visible_peers) + 1,
      cluster_size: state.cluster_size,
      read_only: state.partition_status == :minority,
      raft_state: state.raft_state,
      term: state.term,
      leader: state.leader,
      elections_total: state.elections_total,
      partition_changes_total: state.partition_changes_total
    }
  end

  defp schedule_partition_check do
    Process.send_after(self(), :partition_check, check_interval())
  end

  defp schedule_election_timeout_check do
    Process.send_after(self(), :election_timeout_check, 50)
  end

  defp check_interval do
    Application.get_env(:orchestrator, :partition_check_interval, 5_000)
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat_tick, @heartbeat_interval_ms)
  end
end
