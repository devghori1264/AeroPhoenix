defmodule Orchestrator.Debugger.Session do
  use GenServer
  require Logger
  alias Orchestrator.Debugger.{PTY, ProcessInspector, NetworkCapture, FSBrowser}
  alias Orchestrator.MachineFSM
  @type session_id :: String.t()
  @type machine_id :: String.t()
  @type session_state :: %{
          session_id: session_id(),
          machine_id: machine_id(),
          user_id: String.t(),
          pty: pid() | nil,
          mode: :shell | :inspect | :capture | :browse | :debug,
          subscribers: MapSet.t(),
          metrics: map(),
          breakpoints: MapSet.t(),
          recording: boolean(),
          recording_buffer: list(),
          created_at: DateTime.t(),
          last_activity: DateTime.t()
        }
  @spec start_session(machine_id(), keyword()) :: {:ok, session_id()} | {:error, term()}
  def start_session(machine_id, opts \\ []) do
    session_id = generate_session_id()

    initial_state = %{
      session_id: session_id,
      machine_id: machine_id,
      user_id: Keyword.get(opts, :user_id, "anonymous"),
      pty: nil,
      mode: Keyword.get(opts, :mode, :shell),
      subscribers: MapSet.new(),
      metrics: %{},
      breakpoints: MapSet.new(Keyword.get(opts, :breakpoints, [])),
      recording: Keyword.get(opts, :record, false),
      recording_buffer: [],
      created_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now()
    }

    case GenServer.start(__MODULE__, initial_state, name: via_tuple(session_id)) do
      {:ok, _pid} ->
        Logger.info("Debugger session started",
          session_id: session_id,
          machine_id: machine_id,
          mode: initial_state.mode
        )

        {:ok, session_id}

      {:error, reason} = error ->
        Logger.error("Failed to start debugger session",
          machine_id: machine_id,
          reason: inspect(reason)
        )

        error
    end
  end

  @spec attach(session_id(), pid()) :: {:ok, map()} | {:error, term()}
  def attach(session_id, subscriber_pid) when is_pid(subscriber_pid) do
    GenServer.call(via_tuple(session_id), {:attach, subscriber_pid})
  end

  @spec detach(session_id(), pid()) :: :ok
  def detach(session_id, subscriber_pid) when is_pid(subscriber_pid) do
    GenServer.cast(via_tuple(session_id), {:detach, subscriber_pid})
  end

  @spec send_input(session_id(), binary()) :: :ok | {:error, term()}
  def send_input(session_id, data) when is_binary(data) do
    GenServer.call(via_tuple(session_id), {:send_input, data})
  end

  @spec switch_mode(session_id(), atom()) :: :ok | {:error, term()}
  def switch_mode(session_id, mode) when mode in [:shell, :inspect, :capture, :browse, :debug] do
    GenServer.call(via_tuple(session_id), {:switch_mode, mode})
  end

  @spec set_breakpoint(session_id(), String.t()) :: :ok
  def set_breakpoint(session_id, state) when is_binary(state) do
    GenServer.call(via_tuple(session_id), {:set_breakpoint, state})
  end

  @spec remove_breakpoint(session_id(), String.t()) :: :ok
  def remove_breakpoint(session_id, state) when is_binary(state) do
    GenServer.call(via_tuple(session_id), {:remove_breakpoint, state})
  end

  @spec continue_execution(session_id()) :: :ok | {:error, term()}
  def continue_execution(session_id) do
    GenServer.call(via_tuple(session_id), :continue_execution)
  end

  @spec get_metrics(session_id()) :: {:ok, map()} | {:error, term()}
  def get_metrics(session_id) do
    GenServer.call(via_tuple(session_id), :get_metrics)
  end

  @spec list_files(session_id(), Path.t()) :: {:ok, list()} | {:error, term()}
  def list_files(session_id, path) do
    GenServer.call(via_tuple(session_id), {:list_files, path})
  end

  @spec read_file(session_id(), Path.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(session_id, path) do
    GenServer.call(via_tuple(session_id), {:read_file, path})
  end

  @spec start_capture(session_id(), keyword()) :: :ok | {:error, term()}
  def start_capture(session_id, opts \\ []) do
    GenServer.call(via_tuple(session_id), {:start_capture, opts})
  end

  @spec stop_capture(session_id()) :: {:ok, list()} | {:error, term()}
  def stop_capture(session_id) do
    GenServer.call(via_tuple(session_id), :stop_capture)
  end

  @spec terminate_session(session_id()) :: :ok
  def terminate_session(session_id) do
    GenServer.stop(via_tuple(session_id), :normal)
  end

  @spec list_sessions() :: {:ok, [map()]} | {:error, term()}
  def list_sessions do
    sessions =
      Registry.select(Orchestrator.DebuggerRegistry, [
        {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])
      |> Enum.map(fn {session_id, pid, _value} ->
        try do
          Logger.debug("Querying session info", session_id: session_id)
          GenServer.call(pid, :get_session_info, 100)
        catch
          :exit, _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, sessions}
  end

  @impl true
  def init(state) do
    {:ok, state, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    new_state =
      case state.mode do
        :shell -> initialize_pty(state)
        :inspect -> initialize_inspector(state)
        :capture -> initialize_capture(state)
        :browse -> initialize_browser(state)
        :debug -> initialize_debug_mode(state)
      end

    schedule_metrics_update()
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:attach, subscriber_pid}, _from, state) do
    new_subscribers = MapSet.put(state.subscribers, subscriber_pid)
    Process.monitor(subscriber_pid)

    initial_data = %{
      session_id: state.session_id,
      machine_id: state.machine_id,
      mode: state.mode,
      breakpoints: MapSet.to_list(state.breakpoints),
      metrics: state.metrics,
      created_at: state.created_at
    }

    {:reply, {:ok, initial_data}, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call({:send_input, data}, _from, %{pty: pty} = state) when is_pid(pty) do
    case PTY.send_input(pty, data) do
      :ok ->
        new_state = update_activity(state)
        maybe_record_event(new_state, {:input, data})
        {:reply, :ok, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:switch_mode, new_mode}, _from, state) do
    state = cleanup_current_mode(state)

    new_state =
      case new_mode do
        :shell -> initialize_pty(state)
        :inspect -> initialize_inspector(state)
        :capture -> initialize_capture(state)
        :browse -> initialize_browser(state)
        :debug -> initialize_debug_mode(state)
      end
      |> Map.put(:mode, new_mode)
      |> update_activity()

    broadcast(new_state, {:mode_changed, new_mode})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_breakpoint, state_name}, _from, state) do
    new_breakpoints = MapSet.put(state.breakpoints, state_name)
    new_state = %{state | breakpoints: new_breakpoints}
    :ok = MachineFSM.set_debug_breakpoint(state.machine_id, state_name)
    broadcast(new_state, {:breakpoint_set, state_name})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:remove_breakpoint, state_name}, _from, state) do
    new_breakpoints = MapSet.delete(state.breakpoints, state_name)
    new_state = %{state | breakpoints: new_breakpoints}
    :ok = MachineFSM.remove_debug_breakpoint(state.machine_id, state_name)
    broadcast(new_state, {:breakpoint_removed, state_name})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:continue_execution, _from, state) do
    case MachineFSM.continue_from_breakpoint(state.machine_id) do
      :ok ->
        broadcast(state, :execution_continued)
        {:reply, :ok, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, {:ok, state.metrics}, state}
  end

  @impl true
  def handle_call({:list_files, path}, _from, state) do
    case FSBrowser.list_directory(state.machine_id, path) do
      {:ok, files} ->
        {:reply, {:ok, files}, update_activity(state)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:read_file, path}, _from, state) do
    case FSBrowser.read_file(state.machine_id, path) do
      {:ok, content} ->
        {:reply, {:ok, content}, update_activity(state)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_session_info, _from, state) do
    info = %{
      id: state.session_id,
      machine_id: state.machine_id,
      region: "local",
      status: "active",
      uptime: DateTime.diff(DateTime.utc_now(), state.created_at, :second),
      connected: true,
      created_at: state.created_at
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call({:start_capture, opts}, _from, state) do
    case NetworkCapture.start(state.machine_id, opts) do
      {:ok, capture_pid} ->
        new_state = Map.put(state, :capture_pid, capture_pid)
        broadcast(new_state, :capture_started)
        {:reply, :ok, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:stop_capture, _from, state) do
    case Map.get(state, :capture_pid) do
      nil ->
        {:reply, {:error, :no_active_capture}, state}

      capture_pid ->
        case NetworkCapture.stop(capture_pid) do
          {:ok, packets} ->
            new_state = Map.delete(state, :capture_pid)
            broadcast(new_state, {:capture_stopped, length(packets)})
            {:reply, {:ok, packets}, new_state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_cast({:detach, subscriber_pid}, state) do
    new_subscribers = MapSet.delete(state.subscribers, subscriber_pid)
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_info({:pty_output, data}, state) do
    broadcast(state, {:output, data})
    maybe_record_event(state, {:output, data})
    {:noreply, update_activity(state)}
  end

  @impl true
  def handle_info(:update_metrics, state) do
    {:ok, metrics} = ProcessInspector.get_metrics(state.machine_id)
    new_state = %{state | metrics: metrics}
    broadcast(new_state, {:metrics_updated, metrics})
    schedule_metrics_update()
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    new_state = %{state | subscribers: new_subscribers}

    if MapSet.size(new_subscribers) == 0 do
      Logger.info("No subscribers remaining, terminating session",
        session_id: state.session_id
      )

      {:stop, :normal, new_state}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_current_mode(state)
    Logger.info("Debugger session terminated", session_id: state.session_id)
    :ok
  end

  defp via_tuple(session_id) do
    {:via, Registry, {Orchestrator.DebuggerRegistry, session_id}}
  end

  defp generate_session_id do
    "dbg_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end

  defp initialize_pty(state) do
    case PTY.start_link(state.machine_id, self()) do
      {:ok, pty_pid} ->
        %{state | pty: pty_pid}

      {:error, reason} ->
        Logger.error("Failed to initialize PTY",
          session_id: state.session_id,
          reason: inspect(reason)
        )

        state
    end
  end

  defp initialize_inspector(state) do
    state
  end

  defp initialize_capture(state) do
    state
  end

  defp initialize_browser(state) do
    state
  end

  defp initialize_debug_mode(state) do
    :ok = MachineFSM.enable_debug_mode(state.machine_id)
    state
  end

  defp cleanup_current_mode(%{mode: :shell, pty: pty} = state) when is_pid(pty) do
    PTY.stop(pty)
    %{state | pty: nil}
  end

  defp cleanup_current_mode(%{mode: :debug} = state) do
    :ok = MachineFSM.disable_debug_mode(state.machine_id)
    state
  end

  defp cleanup_current_mode(state), do: state

  defp broadcast(state, message) do
    Enum.each(state.subscribers, fn subscriber ->
      send(subscriber, {:debug_session, state.session_id, message})
    end)
  end

  defp update_activity(state) do
    %{state | last_activity: DateTime.utc_now()}
  end

  defp maybe_record_event(%{recording: true} = state, event) do
    timestamp = DateTime.utc_now()
    recorded_event = {timestamp, event}
    new_buffer = [recorded_event | state.recording_buffer]
    limited_buffer = Enum.take(new_buffer, 10_000)
    %{state | recording_buffer: limited_buffer}
  end

  defp maybe_record_event(state, _event), do: state

  defp schedule_metrics_update do
    Process.send_after(self(), :update_metrics, 1_000)
  end
end
