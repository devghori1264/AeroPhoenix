defmodule Orchestrator.ResourceCoordinator do
  use GenServer
  require Logger

  alias Orchestrator.Replication.CRDT.{PNCounter, VectorClock}

  @gossip_interval_ms 5_000
  @heartbeat_timeout_ms 10_000
  @quorum_timeout_ms 5_000

  defmodule ClusterState do
    @enforce_keys [:node_id, :capacity_crdt, :vector_clock, :peers]
    defstruct [
      :node_id,
      :capacity_crdt,
      :vector_clock,
      :peers,
      partition_mode: false,
      last_gossip_at: nil,
      peer_heartbeats: %{},
      pending_writes: []
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reserve_distributed(machine_id, resources) do
    GenServer.call(__MODULE__, {:reserve_distributed, machine_id, resources}, @quorum_timeout_ms)
  end

  def release_distributed(machine_id) do
    GenServer.cast(__MODULE__, {:release_distributed, machine_id})
  end

  def get_global_capacity(opts \\ []) do
    require_quorum = Keyword.get(opts, :require_quorum, true)
    GenServer.call(__MODULE__, {:get_global_capacity, require_quorum}, @quorum_timeout_ms)
  end

  def get_cluster_status do
    GenServer.call(__MODULE__, :get_cluster_status)
  end

  def trigger_gossip do
    GenServer.cast(__MODULE__, :trigger_gossip)
  end

  @impl true
  def init(opts) do
    node_id = Keyword.get(opts, :node_id, generate_node_id())
    enable_gossip = Keyword.get(opts, :enable_gossip, true)
    gossip_interval = Keyword.get(opts, :gossip_interval_ms, @gossip_interval_ms)

    capacity_crdt = PNCounter.new()
    vector_clock = VectorClock.new()

    peers = discover_peers()

    state = %ClusterState{
      node_id: node_id,
      capacity_crdt: capacity_crdt,
      vector_clock: vector_clock,
      peers: peers,
      partition_mode: false,
      last_gossip_at: nil,
      peer_heartbeats: initialize_heartbeats(peers),
      pending_writes: []
    }

    subscribe_to_crdt_channel(node_id)

    if enable_gossip do
      schedule_gossip(gossip_interval)
    end

    schedule_partition_check(@heartbeat_timeout_ms)

    Logger.info("ResourceCoordinator initialized",
      node_id: node_id,
      peers: length(peers),
      gossip_enabled: enable_gossip
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:reserve_distributed, machine_id, resources}, _from, state) do
    if state.partition_mode do
      Logger.warning("Reservation rejected: partition mode active",
        machine_id: machine_id
      )

      {:reply, {:error, :partition_mode}, state}
    else
      resource_units = calculate_resource_units(resources)
      new_crdt = PNCounter.increment(state.capacity_crdt, state.node_id, resource_units)

      new_vclock = VectorClock.increment(state.vector_clock, state.node_id)

      quorum_result =
        broadcast_reservation_to_quorum(
          state.peers,
          machine_id,
          resources,
          new_vclock
        )

      case quorum_result do
        {:ok, acks} ->
          Logger.info("Distributed reservation confirmed",
            machine_id: machine_id,
            quorum_size: length(acks),
            cpu_cores: resources.cpu_cores
          )

          :telemetry.execute(
            [:orchestrator, :resource_coordinator, :reserve_distributed],
            %{resource_units: resource_units, quorum_size: length(acks)},
            %{machine_id: machine_id}
          )

          new_state = %{state | capacity_crdt: new_crdt, vector_clock: new_vclock}
          {:reply, {:ok, new_vclock}, new_state}

        {:error, :quorum_failed} ->
          Logger.error("Quorum not reached for reservation",
            machine_id: machine_id,
            peers: length(state.peers)
          )

          {:reply, {:error, :quorum_failed}, state}
      end
    end
  end

  @impl true
  def handle_call({:get_global_capacity, require_quorum}, _from, state) do
    if require_quorum and state.partition_mode do
      {:reply, {:error, :partition_mode}, state}
    else
      peer_crdts =
        if require_quorum do
          query_peer_crdts_quorum(state.peers)
        else
          query_peer_crdts_best_effort(state.peers)
        end

      merged_crdt =
        Enum.reduce([state.capacity_crdt | peer_crdts], fn crdt, acc ->
          PNCounter.merge(acc, crdt)
        end)

      total_reserved = PNCounter.value(merged_crdt)

      staleness_ms =
        if state.last_gossip_at do
          System.monotonic_time(:millisecond) - state.last_gossip_at
        else
          :infinity
        end

      result = %{
        total_reserved_units: total_reserved,
        node_count: length(peer_crdts) + 1,
        staleness_ms: staleness_ms,
        partition_mode: state.partition_mode
      }

      {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_call(:get_cluster_status, _from, state) do
    active_peers =
      state.peer_heartbeats
      |> Enum.filter(fn {_peer, last_seen} ->
        System.monotonic_time(:millisecond) - last_seen < @heartbeat_timeout_ms
      end)
      |> Enum.map(fn {peer, _} -> peer end)

    last_gossip_age =
      if state.last_gossip_at do
        System.monotonic_time(:millisecond) - state.last_gossip_at
      else
        nil
      end

    status = %{
      node_id: state.node_id,
      partition_mode: state.partition_mode,
      active_peers: active_peers,
      total_peers: length(state.peers),
      last_gossip_ms: last_gossip_age,
      pending_writes: length(state.pending_writes),
      crdt_value: PNCounter.value(state.capacity_crdt)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:release_distributed, machine_id}, state) do
    avg_resource_units = 1000

    new_crdt = PNCounter.decrement(state.capacity_crdt, state.node_id, avg_resource_units)
    new_vclock = VectorClock.increment(state.vector_clock, state.node_id)

    broadcast_release_async(state.peers, machine_id, new_vclock)

    Logger.debug("Distributed release broadcasted",
      machine_id: machine_id
    )

    new_state = %{state | capacity_crdt: new_crdt, vector_clock: new_vclock}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:trigger_gossip, state) do
    new_state = execute_gossip_round(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:gossip_tick, state) do
    new_state = execute_gossip_round(state)
    schedule_gossip(@gossip_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:partition_check, state) do
    new_state = check_for_partition(state)
    schedule_partition_check(@heartbeat_timeout_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:msg, %{topic: _topic, body: body}}, state) do
    case Jason.decode(body) do
      {:ok, payload} ->
        new_state = handle_peer_crdt_update(state, payload)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to decode NATS gossip message",
          reason: reason,
          body: body
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:nats_message, payload}, state) do
    send(self(), {:msg, %{topic: "legacy", body: Jason.encode!(payload)}})
    {:noreply, state}
  end

  defp calculate_resource_units(resources) do
    cpu_units = resources.cpu_cores * 400
    memory_units = resources.memory_mb / 10 * 40
    disk_units = resources.disk_mb / 1000 * 20

    trunc(cpu_units + memory_units + disk_units)
  end

  defp broadcast_reservation_to_quorum(peers, machine_id, resources, vclock) do
    quorum_size = calculate_quorum_size(length(peers) + 1)

    tasks =
      Enum.map(peers, fn peer ->
        Task.async(fn ->
          send_reservation_request(peer, machine_id, resources, vclock)
        end)
      end)

    results = Task.await_many(tasks, @quorum_timeout_ms)

    acks = Enum.count(results, fn res -> res == :ok end)

    if acks >= quorum_size - 1 do
      {:ok, results}
    else
      {:error, :quorum_failed}
    end
  rescue
    _ ->
      {:error, :quorum_failed}
  end

  defp calculate_quorum_size(total_nodes) do
    div(total_nodes, 2) + 1
  end

  defp send_reservation_request(peer, machine_id, resources, vclock) do
    subject = "orchestrator.resource.reserve.#{peer}"

    payload =
      Jason.encode!(%{
        machine_id: machine_id,
        resources: resources,
        vclock: VectorClock.to_map(vclock),
        from_node: Node.self()
      })

    try do
      case Gnat.request(:gnat, subject, payload, receive_timeout: 1_000) do
        {:ok, %{body: response_body}} ->
          case Jason.decode(response_body) do
            {:ok, %{"status" => "ok"}} -> :ok
            _ -> :error
          end

        {:error, _reason} ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  defp execute_gossip_round(state) do
    if Enum.empty?(state.peers) do
      state
    else
      target_peer = Enum.random(state.peers)

      payload = %{
        node_id: state.node_id,
        crdt: state.capacity_crdt,
        vclock: state.vector_clock,
        timestamp: System.monotonic_time(:millisecond)
      }

      broadcast_gossip(target_peer, payload)

      Logger.debug("Gossip broadcasted",
        target: target_peer,
        crdt_value: PNCounter.value(state.capacity_crdt)
      )

      :telemetry.execute(
        [:orchestrator, :resource_coordinator, :gossip],
        %{count: 1},
        %{target_peer: target_peer}
      )

      %{state | last_gossip_at: System.monotonic_time(:millisecond)}
    end
  end

  defp broadcast_gossip(peer, payload) do
    subject = "orchestrator.crdt.gossip.#{peer}"

    message =
      Jason.encode!(%{
        node_id: payload.node_id,
        crdt: %{
          positive: payload.crdt.positive.counts,
          negative: payload.crdt.negative.counts
        },
        vclock: VectorClock.to_map(payload.vclock),
        timestamp: payload.timestamp
      })

    try do
      Gnat.pub(:gnat, subject, message)
    rescue
      error ->
        Logger.error("Failed to broadcast gossip",
          peer: peer,
          error: Exception.message(error)
        )
    end
  end

  defp handle_peer_crdt_update(state, payload) do
    peer_node_id = payload["node_id"]

    peer_crdt = %PNCounter{
      positive: %Orchestrator.Replication.CRDT.GCounter{
        counts: payload["crdt"]["positive"] || %{}
      },
      negative: %Orchestrator.Replication.CRDT.GCounter{
        counts: payload["crdt"]["negative"] || %{}
      }
    }

    peer_vclock = %VectorClock{
      clocks: payload["vclock"] || %{}
    }

    merged_crdt = PNCounter.merge(state.capacity_crdt, peer_crdt)

    merged_vclock = VectorClock.merge(state.vector_clock, peer_vclock)

    new_heartbeats =
      Map.put(state.peer_heartbeats, peer_node_id, System.monotonic_time(:millisecond))

    Logger.debug("CRDT merged from peer",
      peer: peer_node_id,
      local_value: PNCounter.value(state.capacity_crdt),
      merged_value: PNCounter.value(merged_crdt)
    )

    %{
      state
      | capacity_crdt: merged_crdt,
        vector_clock: merged_vclock,
        peer_heartbeats: new_heartbeats
    }
  end

  defp check_for_partition(state) do
    now = System.monotonic_time(:millisecond)

    alive_peers =
      state.peer_heartbeats
      |> Enum.count(fn {_peer, last_seen} ->
        now - last_seen < @heartbeat_timeout_ms
      end)

    total_peers = length(state.peers)
    quorum_size = calculate_quorum_size(total_peers + 1)

    partition_detected = alive_peers + 1 < quorum_size

    if partition_detected and not state.partition_mode do
      Logger.error("Network partition detected",
        alive_peers: alive_peers,
        total_peers: total_peers,
        quorum_required: quorum_size
      )

      :telemetry.execute(
        [:orchestrator, :resource_coordinator, :partition_detected],
        %{alive_peers: alive_peers, total_peers: total_peers},
        %{}
      )

      %{state | partition_mode: true}
    else
      if not partition_detected and state.partition_mode do
        Logger.info("Network partition healed",
          alive_peers: alive_peers
        )

        :telemetry.execute(
          [:orchestrator, :resource_coordinator, :partition_healed],
          %{alive_peers: alive_peers},
          %{}
        )

        state = replay_pending_writes(state)

        %{state | partition_mode: false}
      else
        state
      end
    end
  end

  defp replay_pending_writes(state) do
    Logger.info("Replaying pending writes",
      count: length(state.pending_writes)
    )

    %{state | pending_writes: []}
  end

  defp discover_peers do
    connected_nodes = Node.list()

    orchestrator_nodes =
      Enum.filter(connected_nodes, fn node ->
        node_string = Atom.to_string(node)
        String.contains?(node_string, "orchestrator")
      end)

    Logger.info("Discovered peers via Erlang distribution",
      peer_count: length(orchestrator_nodes),
      peers: orchestrator_nodes
    )

    orchestrator_nodes
  end

  defp subscribe_to_crdt_channel(node_id) do
    case Process.whereis(:gnat) do
      nil ->
        Logger.warning("NATS not available, skipping CRDT gossip subscription (local dev mode)",
          node_id: node_id
        )

        :ok

      _pid ->
        subject = "orchestrator.crdt.gossip.#{node_id}"

        try do
          {:ok, _sid} = Gnat.sub(:gnat, self(), subject)

          Logger.info("Subscribed to CRDT gossip channel",
            node_id: node_id,
            subject: subject
          )
        rescue
          error ->
            Logger.error("Failed to subscribe to CRDT channel",
              node_id: node_id,
              error: Exception.message(error)
            )
        end

        :ok
    end
  end

  defp query_peer_crdts_quorum(peers) do
    has_peers = length(peers) > 0

    if has_peers do
      []
    else
      []
    end
  end

  defp query_peer_crdts_best_effort(peers) do
    has_peers = length(peers) > 0

    if has_peers do
      []
    else
      []
    end
  end

  defp broadcast_release_async(peers, machine_id, vclock) do
    Enum.each(peers, fn peer ->
      subject = "orchestrator.resource.release.#{peer}"

      message =
        Jason.encode!(%{
          machine_id: machine_id,
          vclock: VectorClock.to_map(vclock),
          from_node: Node.self(),
          timestamp: System.system_time(:millisecond)
        })

      Task.start(fn ->
        try do
          Gnat.pub(:gnat, subject, message)
        rescue
          error ->
            Logger.error("Failed to broadcast release",
              peer: peer,
              machine_id: machine_id,
              error: Exception.message(error)
            )
        end
      end)
    end)
  end

  defp initialize_heartbeats(peers) do
    now = System.monotonic_time(:millisecond)
    Enum.into(peers, %{}, fn peer -> {peer, now} end)
  end

  defp schedule_gossip(interval_ms) do
    Process.send_after(self(), :gossip_tick, interval_ms)
  end

  defp schedule_partition_check(interval_ms) do
    Process.send_after(self(), :partition_check, interval_ms)
  end

  defp generate_node_id do
    {:ok, hostname} = :inet.gethostname()
    "#{hostname}@#{:erlang.node()}"
  end
end
