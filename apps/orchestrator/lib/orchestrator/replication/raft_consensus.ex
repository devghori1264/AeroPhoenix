defmodule Orchestrator.Replication.RaftConsensus do
  use GenServer
  require Logger
  @election_timeout_min 150
  @election_timeout_max 300
  @heartbeat_interval 50
  defmodule State do
    defstruct [
      :current_term,
      :voted_for,
      :log,
      :commit_index,
      :last_applied,
      :role,
      :leader_id,
      :votes_received,
      :next_index,
      :match_index,
      :node_id,
      :cluster_nodes,
      :election_timer,
      :heartbeat_timer,
      :on_commit
    ]
  end

  defmodule LogEntry do
    defstruct [:term, :index, :command]
  end

  def start_link(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(node_id))
  end

  def append_command(node_id, command) do
    GenServer.call(via_tuple(node_id), {:append_command, command})
  end

  def request_vote(node_id, request) do
    GenServer.call(via_tuple(node_id), {:request_vote, request})
  end

  def append_entries(node_id, request) do
    GenServer.call(via_tuple(node_id), {:append_entries, request})
  end

  def get_state(node_id) do
    GenServer.call(via_tuple(node_id), :get_state)
  end

  @impl true
  def init(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    cluster_nodes = Keyword.get(opts, :cluster_nodes, [])
    on_commit = Keyword.get(opts, :on_commit, fn _entry -> :ok end)

    state = %State{
      current_term: 0,
      voted_for: nil,
      log: [],
      commit_index: 0,
      last_applied: 0,
      role: :follower,
      leader_id: nil,
      votes_received: MapSet.new(),
      next_index: %{},
      match_index: %{},
      node_id: node_id,
      cluster_nodes: cluster_nodes,
      election_timer: nil,
      heartbeat_timer: nil,
      on_commit: on_commit
    }

    state = reset_election_timer(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:append_command, command}, _from, %{role: :leader} = state) do
    new_entry = %LogEntry{
      term: state.current_term,
      index: length(state.log) + 1,
      command: command
    }

    new_log = state.log ++ [new_entry]
    new_state = %{state | log: new_log}
    send_append_entries(new_state)
    {:reply, {:ok, new_entry.index}, new_state}
  end

  @impl true
  def handle_call({:append_command, _command}, _from, state) do
    {:reply, {:error, :not_leader, state.leader_id}, state}
  end

  @impl true
  def handle_call({:request_vote, request}, _from, state) do
    %{
      term: candidate_term,
      candidate_id: _candidate_id,
      last_log_index: _candidate_last_index,
      last_log_term: _candidate_last_term
    } = request

    {reply, new_state} =
      cond do
        candidate_term < state.current_term ->
          {{:vote_rejected, state.current_term}, state}

        candidate_term > state.current_term ->
          state = become_follower(state, candidate_term)
          process_vote_request(request, state)

        true ->
          process_vote_request(request, state)
      end

    new_state = reset_election_timer(new_state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call({:append_entries, request}, _from, state) do
    %{
      term: leader_term,
      leader_id: leader_id,
      prev_log_index: _prev_index,
      prev_log_term: _prev_term,
      entries: _entries,
      leader_commit: _leader_commit
    } = request

    {reply, new_state} =
      cond do
        leader_term < state.current_term ->
          {{:rejected, state.current_term}, state}

        leader_term > state.current_term ->
          state = become_follower(state, leader_term, leader_id)
          process_append_entries(request, state)

        true ->
          state = %{state | leader_id: leader_id}
          process_append_entries(request, state)
      end

    new_state = reset_election_timer(new_state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    info = %{
      node_id: state.node_id,
      role: state.role,
      current_term: state.current_term,
      leader_id: state.leader_id,
      log_length: length(state.log),
      commit_index: state.commit_index,
      last_applied: state.last_applied
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info(:election_timeout, state) do
    new_state = start_election(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:send_heartbeats, %{role: :leader} = state) do
    send_append_entries(state)
    state = schedule_heartbeat(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:send_heartbeats, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:vote_response, from_node, response}, %{role: :candidate} = state) do
    case response do
      {:vote_granted, _term} ->
        votes = MapSet.put(state.votes_received, from_node)
        new_state = %{state | votes_received: votes}
        majority = div(length(state.cluster_nodes) + 1, 2) + 1

        if MapSet.size(votes) >= majority do
          {:noreply, become_leader(new_state)}
        else
          {:noreply, new_state}
        end

      {:vote_rejected, term} when term > state.current_term ->
        {:noreply, become_follower(state, term)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:vote_response, _from, _response}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:append_response, from_node, response}, %{role: :leader} = state) do
    case response do
      {:success, match_index} ->
        new_match_index = Map.put(state.match_index, from_node, match_index)
        new_next_index = Map.put(state.next_index, from_node, match_index + 1)
        new_state = %{state | match_index: new_match_index, next_index: new_next_index}
        new_state = try_commit_entries(new_state)
        {:noreply, new_state}

      {:rejected, _term} ->
        next_index = Map.get(state.next_index, from_node, 1)
        new_next_index = Map.put(state.next_index, from_node, max(1, next_index - 1))
        {:noreply, %{state | next_index: new_next_index}}
    end
  end

  @impl true
  def handle_info({:append_response, _from, _response}, state) do
    {:noreply, state}
  end

  defp via_tuple(node_id) do
    {:via, Registry, {Orchestrator.Registry, {:raft, node_id}}}
  end

  defp reset_election_timer(state) do
    if state.election_timer, do: Process.cancel_timer(state.election_timer)
    timeout = :rand.uniform(@election_timeout_max - @election_timeout_min) + @election_timeout_min
    timer = Process.send_after(self(), :election_timeout, timeout)
    %{state | election_timer: timer}
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)
    timer = Process.send_after(self(), :send_heartbeats, @heartbeat_interval)
    %{state | heartbeat_timer: timer}
  end

  defp start_election(state) do
    new_term = state.current_term + 1

    new_state = %{
      state
      | current_term: new_term,
        role: :candidate,
        voted_for: state.node_id,
        votes_received: MapSet.new([state.node_id]),
        leader_id: nil
    }

    Logger.info("Node #{state.node_id} starting election for term #{new_term}")
    {last_log_index, last_log_term} = get_last_log_info(state)

    request = %{
      term: new_term,
      candidate_id: state.node_id,
      last_log_index: last_log_index,
      last_log_term: last_log_term
    }

    Enum.each(state.cluster_nodes, fn node ->
      Task.start(fn ->
        response = request_vote(node, request)
        send(self(), {:vote_response, node, response})
      end)
    end)

    reset_election_timer(new_state)
  end

  defp become_leader(state) do
    Logger.info("Node #{state.node_id} became leader for term #{state.current_term}")

    next_index =
      state.cluster_nodes
      |> Enum.map(fn node -> {node, length(state.log) + 1} end)
      |> Enum.into(%{})

    match_index =
      state.cluster_nodes
      |> Enum.map(fn node -> {node, 0} end)
      |> Enum.into(%{})

    new_state = %{
      state
      | role: :leader,
        leader_id: state.node_id,
        next_index: next_index,
        match_index: match_index
    }

    if new_state.election_timer, do: Process.cancel_timer(new_state.election_timer)
    new_state = schedule_heartbeat(new_state)
    send_append_entries(new_state)
    new_state
  end

  defp become_follower(state, new_term, leader_id \\ nil) do
    Logger.info("Node #{state.node_id} became follower for term #{new_term}")

    %{
      state
      | current_term: new_term,
        role: :follower,
        voted_for: nil,
        leader_id: leader_id,
        votes_received: MapSet.new()
    }
  end

  defp process_vote_request(request, state) do
    %{
      term: candidate_term,
      candidate_id: candidate_id,
      last_log_index: candidate_last_index,
      last_log_term: candidate_last_term
    } = request

    {my_last_index, my_last_term} = get_last_log_info(state)

    grant_vote =
      (state.voted_for == nil or state.voted_for == candidate_id) and
        log_is_up_to_date?(candidate_last_index, candidate_last_term, my_last_index, my_last_term)

    if grant_vote do
      new_state = %{state | voted_for: candidate_id, current_term: candidate_term}
      {{:vote_granted, candidate_term}, new_state}
    else
      {{:vote_rejected, state.current_term}, state}
    end
  end

  defp process_append_entries(request, state) do
    %{
      prev_log_index: prev_index,
      prev_log_term: prev_term,
      entries: entries,
      leader_commit: leader_commit
    } = request

    if log_matches?(state.log, prev_index, prev_term) do
      new_log = append_new_entries(state.log, prev_index, entries)
      new_state = %{state | log: new_log}
      new_commit_index = min(leader_commit, length(new_log))
      new_state = %{new_state | commit_index: new_commit_index}
      new_state = apply_committed_entries(new_state)
      {{:success, length(new_log)}, new_state}
    else
      {{:rejected, state.current_term}, state}
    end
  end

  defp send_append_entries(state) do
    Enum.each(state.cluster_nodes, fn node ->
      next_index = Map.get(state.next_index, node, 1)
      prev_index = next_index - 1
      prev_term = get_log_term(state.log, prev_index)
      entries = Enum.drop(state.log, next_index - 1)

      request = %{
        term: state.current_term,
        leader_id: state.node_id,
        prev_log_index: prev_index,
        prev_log_term: prev_term,
        entries: entries,
        leader_commit: state.commit_index
      }

      Task.start(fn ->
        response = append_entries(node, request)
        send(self(), {:append_response, node, response})
      end)
    end)
  end

  defp try_commit_entries(state) do
    sorted_match_indices =
      state.match_index
      |> Map.values()
      |> Enum.sort(:desc)

    majority_index = div(length(state.cluster_nodes) + 1, 2)
    majority_match_index = Enum.at(sorted_match_indices, majority_index - 1, 0)

    new_commit_index =
      if majority_match_index > state.commit_index do
        entry = Enum.at(state.log, majority_match_index - 1)

        if entry && entry.term == state.current_term do
          majority_match_index
        else
          state.commit_index
        end
      else
        state.commit_index
      end

    new_state = %{state | commit_index: new_commit_index}
    apply_committed_entries(new_state)
  end

  defp apply_committed_entries(state) do
    if state.commit_index > state.last_applied do
      entries_to_apply =
        Enum.slice(state.log, state.last_applied, state.commit_index - state.last_applied)

      Enum.each(entries_to_apply, fn entry ->
        state.on_commit.(entry)
      end)

      %{state | last_applied: state.commit_index}
    else
      state
    end
  end

  defp get_last_log_info(state) do
    case List.last(state.log) do
      nil -> {0, 0}
      entry -> {entry.index, entry.term}
    end
  end

  defp get_log_term(log, index) do
    case Enum.at(log, index - 1) do
      nil -> 0
      entry -> entry.term
    end
  end

  defp log_matches?(log, index, term) do
    if index == 0 do
      true
    else
      case Enum.at(log, index - 1) do
        nil -> false
        entry -> entry.term == term
      end
    end
  end

  defp log_is_up_to_date?(candidate_index, candidate_term, my_index, my_term) do
    candidate_term > my_term or (candidate_term == my_term and candidate_index >= my_index)
  end

  defp append_new_entries(log, prev_index, new_entries) do
    existing = Enum.take(log, prev_index)
    existing ++ new_entries
  end
end
