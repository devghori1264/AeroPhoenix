defmodule Orchestrator.Replication.GossipProtocol do
  use GenServer
  require Logger

  alias Orchestrator.Replication.{
    MerkleTree,
    PhiAccrualFailureDetector,
    CRDTState,
    VectorClock,
    HybridLogicalClock
  }

  @gossip_interval_ms 30_000
  @heartbeat_interval_ms 5_000
  @default_fanout 3
  @max_fanout 10
  @phi_suspect_threshold 3.0

  def suspect_threshold, do: @phi_suspect_threshold
  @phi_failed_threshold 8.0
  @max_backoff_ms 1_600
  @backoff_jitter_pct 0.2

  @type peer_id :: atom()
  @type delta :: map()

  @type state :: %{
          node_id: peer_id(),
          machine_id: String.t(),
          crdt_state: CRDTState.t(),
          merkle_tree: MerkleTree.t() | nil,
          failure_detectors: %{peer_id() => PhiAccrualFailureDetector.t()},
          peer_backoff: %{peer_id() => {non_neg_integer(), integer()}},
          seen_deltas: MapSet.t(),
          gossip_round: non_neg_integer(),
          metrics: map(),
          gossip_interval_ms: pos_integer(),
          heartbeat_interval_ms: pos_integer(),
          fanout: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    machine_id = Keyword.fetch!(opts, :machine_id)
    name = {:via, Registry, {Orchestrator.Registry, {:gossip, machine_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec trigger_gossip(GenServer.server()) :: :ok
  def trigger_gossip(server) do
    GenServer.cast(server, :trigger_gossip)
  end

  @spec apply_local_delta(GenServer.server(), delta(), CRDTState.t()) :: :ok
  def apply_local_delta(server, delta, updated_crdt) do
    GenServer.cast(server, {:apply_local_delta, delta, updated_crdt})
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    machine_id = Keyword.fetch!(opts, :machine_id)
    crdt_state = Keyword.fetch!(opts, :crdt_state)
    node_id = Node.self()

    state = %{
      node_id: node_id,
      machine_id: machine_id,
      crdt_state: crdt_state,
      merkle_tree: nil,
      failure_detectors: %{},
      peer_backoff: %{},
      seen_deltas: MapSet.new(),
      gossip_round: 0,
      metrics: initialize_metrics(),
      gossip_interval_ms: Keyword.get(opts, :gossip_interval_ms, @gossip_interval_ms),
      heartbeat_interval_ms: Keyword.get(opts, :heartbeat_interval_ms, @heartbeat_interval_ms),
      fanout: Keyword.get(opts, :fanout, @default_fanout)
    }

    :net_kernel.monitor_nodes(true, node_type: :all)

    Phoenix.PubSub.subscribe(Orchestrator.PubSub, "gossip:#{machine_id}")

    schedule_gossip(state.gossip_interval_ms)
    schedule_heartbeat(state.heartbeat_interval_ms)

    Logger.debug("GossipProtocol started",
      machine_id: machine_id,
      node_id: node_id,
      gossip_interval_ms: state.gossip_interval_ms
    )

    {:ok, state}
  end

  @impl true
  def handle_cast(:trigger_gossip, state) do
    new_state = perform_gossip_round(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:apply_local_delta, delta, updated_crdt}, state) do
    new_state = %{state | crdt_state: updated_crdt}

    broadcast_delta(delta, new_state)

    delta_id = extract_delta_id(delta)
    new_state = %{new_state | seen_deltas: MapSet.put(new_state.seen_deltas, delta_id)}

    new_state = update_metric(new_state, :deltas_sent, 1)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = compile_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:gossip_tick, state) do
    new_state = perform_gossip_round(state)
    schedule_gossip(state.gossip_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:heartbeat_tick, state) do
    new_state = send_heartbeats(state)
    schedule_heartbeat(state.heartbeat_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodeup, peer_node, _info}, state) do
    Logger.debug("Peer node connected", peer: peer_node, machine_id: state.machine_id)

    detector = PhiAccrualFailureDetector.init(peer_node, phi_threshold: @phi_failed_threshold)

    new_state = %{
      state
      | failure_detectors: Map.put(state.failure_detectors, peer_node, detector)
    }

    new_state = perform_gossip_round(new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodedown, peer_node, _info}, state) do
    Logger.warning("Peer node disconnected", peer: peer_node, machine_id: state.machine_id)

    {:noreply, state}
  end

  @impl true
  def handle_info({:gossip_push, from_node, merkle_digest}, state) do
    new_state = handle_gossip_push(from_node, merkle_digest, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:gossip_pull_request, from_node, divergent_bucket_ids}, state) do
    new_state = handle_gossip_pull_request(from_node, divergent_bucket_ids, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:gossip_delta, delta}, state) do
    new_state = handle_received_delta(delta, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:heartbeat, from_node}, state) do
    new_state = record_heartbeat(from_node, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp perform_gossip_round(state) do
    merkle_tree = build_merkle_tree(state.crdt_state)

    peers = select_gossip_peers(state)

    new_state =
      Enum.reduce(peers, state, fn peer, acc_state ->
        contact_peer_for_gossip(peer, merkle_tree, acc_state)
      end)

    new_state = %{
      new_state
      | merkle_tree: merkle_tree,
        gossip_round: state.gossip_round + 1
    }

    :telemetry.execute(
      [:orchestrator, :gossip, :round_completed],
      %{
        round: new_state.gossip_round,
        peers_contacted: length(peers),
        failed_peers: count_failed_peers(new_state)
      },
      %{machine_id: state.machine_id}
    )

    Logger.debug("Gossip round completed",
      machine_id: state.machine_id,
      round: new_state.gossip_round,
      peers: length(peers)
    )

    new_state
  end

  defp build_merkle_tree(crdt_state) do
    entries = [
      {crdt_state.machine_id, VectorClock.to_map(crdt_state.vclock)}
    ]

    MerkleTree.build(entries)
  end

  defp select_gossip_peers(state) do
    all_peers = Node.list()

    healthy_peers =
      Enum.filter(all_peers, fn peer ->
        case Map.get(state.failure_detectors, peer) do
          nil ->
            true

          detector ->
            case PhiAccrualFailureDetector.phi(detector) do
              {:ok, phi} -> phi < @phi_failed_threshold
              {:insufficient_data, _} -> true
            end
        end
      end)

    fanout = calculate_adaptive_fanout(length(healthy_peers), state.fanout)

    healthy_peers
    |> Enum.shuffle()
    |> Enum.take(fanout)
  end

  defp calculate_adaptive_fanout(peer_count, base_fanout) do
    cond do
      peer_count <= 10 ->
        min(base_fanout, peer_count)

      peer_count <= 100 ->
        fanout = ceil(:math.log2(peer_count))
        min(fanout, @max_fanout)

      true ->
        @max_fanout
    end
  end

  defp contact_peer_for_gossip(peer, merkle_tree, state) do
    if should_skip_peer_backoff?(peer, state) do
      state
    else
      send_gossip_push(peer, merkle_tree, state)

      update_metric(state, :peers_contacted, 1)
    end
  end

  defp send_gossip_push(peer, merkle_tree, state) do
    digest = %{
      root_hash: merkle_tree.root,
      entry_count: merkle_tree.entry_count,
      from_node: state.node_id
    }

    try do
      send({__MODULE__, peer}, {:gossip_push, state.node_id, digest})
    rescue
      error ->
        Logger.warning("Failed to send gossip push to peer",
          peer: peer,
          error: inspect(error)
        )

        apply_backoff(peer, state)
    end

    state
  end

  defp handle_gossip_push(from_node, their_digest, state) do
    if state.merkle_tree != nil and state.merkle_tree.root != their_digest.root_hash do
      request_divergent_buckets(from_node, state)
    else
      state
    end
  end

  defp request_divergent_buckets(from_node, state) do
    try do
      send({__MODULE__, from_node}, {:gossip_pull_request, state.node_id, :all})
    rescue
      error ->
        Logger.warning("Failed to request buckets from peer",
          peer: from_node,
          error: inspect(error)
        )
    end

    state
  end

  defp handle_gossip_pull_request(_from_node, :all, state) do
    state
  end

  defp send_heartbeats(state) do
    all_peers = Node.list()

    Enum.each(all_peers, fn peer ->
      try do
        send({__MODULE__, peer}, {:heartbeat, state.node_id})
      rescue
        _error ->
          :ok
      end
    end)

    state
  end

  defp record_heartbeat(from_node, state) do
    detector =
      case Map.get(state.failure_detectors, from_node) do
        nil ->
          PhiAccrualFailureDetector.init(from_node, phi_threshold: @phi_failed_threshold)

        existing_detector ->
          existing_detector
      end

    updated_detector = PhiAccrualFailureDetector.heartbeat(detector)

    new_state = %{
      state
      | failure_detectors: Map.put(state.failure_detectors, from_node, updated_detector)
    }

    case PhiAccrualFailureDetector.suspicion_level(updated_detector) do
      :failed ->
        :ok

      :suspect ->
        Logger.debug("Peer suspected",
          peer: from_node,
          phi:
            case PhiAccrualFailureDetector.phi(updated_detector) do
              {:ok, val} -> Float.round(val, 2)
              _ -> nil
            end
        )

      level when level in [:healthy, :warning, :unknown] ->
        :ok
    end

    new_state
  end

  defp broadcast_delta(delta, state) do
    Phoenix.PubSub.broadcast(
      Orchestrator.PubSub,
      "gossip:#{state.machine_id}",
      {:gossip_delta, delta}
    )
  end

  defp handle_received_delta(delta, state) do
    try do
      delta_id = extract_delta_id(delta)

      if MapSet.member?(state.seen_deltas, delta_id) do
        state
      else
        case CRDTState.merge_delta(state.crdt_state, delta) do
          {:ok, updated_crdt} ->
            new_state = %{
              state
              | crdt_state: updated_crdt,
                seen_deltas: MapSet.put(state.seen_deltas, delta_id)
            }

            new_state = update_metric(new_state, :deltas_received, 1)

            Logger.debug("Merged delta from peer",
              machine_id: state.machine_id,
              delta_id: delta_id
            )

            new_state

          {:error, reason} ->
            Logger.error("Failed to merge delta",
              machine_id: state.machine_id,
              reason: reason
            )

            state
        end
      end
    rescue
      _ ->
        Logger.warning("Received malformed delta", delta: inspect(delta))
        state
    end
  end

  defp extract_delta_id(delta) do
    {delta.machine_id, delta.node_id, HybridLogicalClock.to_timestamp(delta.hlc)}
  end

  defp should_skip_peer_backoff?(peer, state) do
    case Map.get(state.peer_backoff, peer) do
      nil ->
        false

      {_attempt_count, next_retry_at} ->
        System.monotonic_time(:millisecond) < next_retry_at
    end
  end

  defp apply_backoff(peer, state) do
    {attempt_count, _next_retry} = Map.get(state.peer_backoff, peer, {0, 0})

    base_delay = min(@max_backoff_ms, 100 * :math.pow(2, attempt_count))

    jitter = base_delay * @backoff_jitter_pct * (:rand.uniform() - 0.5) * 2
    delay = round(base_delay + jitter)

    next_retry_at = System.monotonic_time(:millisecond) + delay

    new_backoff = Map.put(state.peer_backoff, peer, {attempt_count + 1, next_retry_at})

    %{state | peer_backoff: new_backoff}
  end

  defp initialize_metrics do
    %{
      deltas_sent: 0,
      deltas_received: 0,
      peers_contacted: 0,
      gossip_rounds: 0
    }
  end

  defp update_metric(state, metric_name, increment) do
    updated_metrics = Map.update!(state.metrics, metric_name, &(&1 + increment))
    %{state | metrics: updated_metrics}
  end

  defp count_failed_peers(state) do
    state.failure_detectors
    |> Enum.count(fn {_peer, detector} ->
      PhiAccrualFailureDetector.is_failed?(detector)
    end)
  end

  defp compile_stats(state) do
    active_peers =
      state.failure_detectors
      |> Enum.count(fn {_peer, detector} ->
        not PhiAccrualFailureDetector.is_failed?(detector)
      end)

    %{
      machine_id: state.machine_id,
      node_id: state.node_id,
      gossip_round: state.gossip_round,
      active_peers: active_peers,
      failed_peers: count_failed_peers(state),
      total_peers: map_size(state.failure_detectors),
      deltas_sent: state.metrics.deltas_sent,
      deltas_received: state.metrics.deltas_received,
      seen_deltas_count: MapSet.size(state.seen_deltas),
      merkle_tree_stats: if(state.merkle_tree, do: MerkleTree.stats(state.merkle_tree), else: nil)
    }
  end

  defp schedule_gossip(interval_ms) do
    Process.send_after(self(), :gossip_tick, interval_ms)
  end

  defp schedule_heartbeat(interval_ms) do
    Process.send_after(self(), :heartbeat_tick, interval_ms)
  end
end
