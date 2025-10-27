defmodule Orchestrator.MachineFSM do
  use GenServer
  require Logger
  alias Orchestrator.{Repo, Machine, FlydClient, MachineEvent}

  @type state :: %{
          id: String.t(),
          status: atom(),
          target: map() | nil,
          retry_count: non_neg_integer(),
          timer_ref: reference() | nil
        }

  @retry_limit 5
  @retry_delay_ms 1000

  def start_link(%{id: id} = init) when is_binary(id) do
    GenServer.start_link(__MODULE__, init, name: via_tuple(id))
  end

  defp via_tuple(id), do: {:via, Registry, {Orchestrator.FSMRegistry, id}}

  @spec create_or_update(map()) :: {:ok, pid()} | {:error, any()}
  def create_or_update(attrs) do
    id = Map.get(attrs, "id") || Map.get(attrs, :id)
    Orchestrator.MachineManager.ensure_started(id, attrs)
  end


  def init(init) do
    id = to_string(init["id"] || init[:id] || UUID.uuid4())
    machine = Repo.get_by(Machine, id: id)
    initial_status = (machine && String.to_atom(machine.status)) || :pending

    state = %{id: id, status: initial_status, target: nil, retry_count: 0, timer_ref: nil}
    Logger.info("MachineFSM[#{id}] started with status #{inspect(initial_status)}")
    {:ok, state}
  end

  def handle_call({:command, "start"}, _from, state) do
    do_start(state)
  end

  def handle_call({:command, "stop"}, _from, state) do
    do_stop(state)
  end

  def handle_call({:command, "migrate", target}, _from, state) do
    do_migrate(state, target)
  end

  def handle_info({:retry, action}, state) do
    Logger.info("Retrying #{inspect(action)} for #{state.id}")
    case action do
      {:start} -> do_start(state)
      {:migrate, target} -> do_migrate(state, target)
      _ -> {:noreply, state}
    end
  end

  defp persist_event(machine_id, type, payload) do
    %MachineEvent{}
    |> MachineEvent.changeset(%{machine_id: machine_id, type: type, payload: payload, created_at: DateTime.utc_now()})
    |> Repo.insert!()
  end

  defp do_start(state) do
    with {:ok, resp} <- FlydClient.start_machine(state.id),
          :ok <- persist_db_update(state.id, %{status: "running", last_seen_at: DateTime.utc_now()} ) do
      persist_event(state.id, "started", resp)
      broadcast_update(state.id)
      {:reply, {:ok, resp}, %{state | status: :running, retry_count: 0}}
    else
      {:error, reason} ->
        Logger.warn("start failed for #{state.id}: #{inspect(reason)}")
        schedule_retry({:start}, state)
    end
  end

  defp do_stop(state) do
    case FlydClient.stop_machine(state.id) do
      {:ok, resp} ->
        persist_db_update(state.id, %{status: "stopped"})
        persist_event(state.id, "stopped", resp)
        broadcast_update(state.id)
        {:reply, {:ok, resp}, %{state | status: :stopped, retry_count: 0}}
      {:error, reason} ->
        schedule_retry({:stop}, state)
    end
  end

  defp do_migrate(state, target) do
    case FlydClient.migrate_machine(state.id, target) do
      {:ok, resp} ->
        persist_db_update(state.id, %{status: "migrating", region: target, last_seen_at: DateTime.utc_now()})
        persist_event(state.id, "migrate_started", resp)
        broadcast_update(state.id)
        {:reply, {:ok, resp}, %{state | status: :migrating, retry_count: 0}}
      {:error, reason} ->
        schedule_retry({:migrate, target}, state)
    end
  end

  defp schedule_retry(action, state) do
    if state.retry_count >= @retry_limit do
      Logger.error("Exceeded retry limit for #{state.id} action #{inspect(action)}")
      persist_event(state.id, "failed_retry", %{action: action, reason: "retry_limit"})
      {:reply, {:error, :retry_exhausted}, state}
    else
      delay = trunc(:math.pow(2, state.retry_count) * @retry_delay_ms)
      Process.send_after(self(), {:retry, action}, delay)
      {:noreply, %{state | retry_count: state.retry_count + 1}}
    end
  end

  defp persist_db_update(id, attrs) do
    Repo.transaction(fn ->
      case Repo.get(Machine, id) do
        nil ->
          %Machine{} |> Machine.changeset(Map.put(attrs, "id", id)) |> Repo.insert!()
          :ok
        m ->
          m |> Machine.changeset(Enum.into(attrs, %{})) |> Repo.update!()
          :ok
      end
    end)
  end

  defp broadcast_update(id) do
    case Repo.get(Machine, id) do
      nil -> :ok
      m ->
        Orchestrator.PubSub.publish_machine_update(m)
    end
  end
end
