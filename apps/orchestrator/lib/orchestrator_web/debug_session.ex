defmodule OrchestratorWeb.DebugSession do
  use GenServer
  require Logger
  alias Orchestrator.{Machine, Repo}
  alias Machine.Proto.{DebugService.Stub, PTYRequest, PTYInput, PTYResize}
  @pty_buffer_size 8192
  @reconnect_interval_ms 5_000
  @max_reconnect_attempts 3
  @session_timeout_ms 28_800_000
  defstruct [
    :id,
    :machine_id,
    :machine,
    :user,
    :shell,
    :cwd,
    :rows,
    :cols,
    :env,
    :channel_pid,
    :grpc_channel,
    :grpc_stream,
    :created_at,
    :last_activity_at,
    :output_buffer,
    :reconnect_attempts,
    :status
  ]

  def create(params) do
    session_id = UUID.uuid4()

    case GenServer.start_link(__MODULE__, Map.put(params, :id, session_id),
           name: via_tuple(session_id)
         ) do
      {:ok, pid} ->
        session = GenServer.call(pid, :get_session)
        {:ok, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_input(session, data) do
    GenServer.call(via_tuple(session.id), {:send_input, data})
  end

  def resize(session, rows, cols) do
    GenServer.call(via_tuple(session.id), {:resize, rows, cols})
  end

  def terminate(session) do
    GenServer.stop(via_tuple(session.id), :normal)
  end

  def get_session(session_id) do
    GenServer.call(via_tuple(session_id), :get_session)
  end

  @impl true
  def init(params) do
    machine = Repo.get!(Machine, params.machine_id)

    state = %__MODULE__{
      id: params.id,
      machine_id: params.machine_id,
      machine: machine,
      user: params.user,
      shell: params.shell,
      cwd: params.cwd,
      rows: params.rows,
      cols: params.cols,
      env: params.env || %{},
      channel_pid: params.channel_pid,
      created_at: DateTime.utc_now(),
      last_activity_at: DateTime.utc_now(),
      output_buffer: [],
      reconnect_attempts: 0,
      status: :connecting
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_session, _from, state) do
    session = %{
      id: state.id,
      machine_id: state.machine_id,
      user: state.user,
      created_at: state.created_at,
      status: state.status
    }

    {:reply, session, state}
  end

  @impl true
  def handle_call({:send_input, data}, _from, state) do
    case send_pty_input(state, data) do
      :ok ->
        state = update_last_activity(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:resize, rows, cols}, _from, state) do
    case send_pty_resize(state, rows, cols) do
      :ok ->
        state = %{state | rows: rows, cols: cols}
        state = update_last_activity(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case establish_grpc_connection(state) do
      {:ok, channel, stream} ->
        Logger.info("Debug session connected: session=#{state.id} machine=#{state.machine_id}")

        state = %{
          state
          | grpc_channel: channel,
            grpc_stream: stream,
            status: :connected,
            reconnect_attempts: 0
        }

        spawn_link(fn -> read_pty_output(stream, self()) end)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to connect debug session: #{inspect(reason)}")

        if state.reconnect_attempts < @max_reconnect_attempts do
          Process.send_after(self(), :connect, @reconnect_interval_ms)
          state = %{state | reconnect_attempts: state.reconnect_attempts + 1}
          {:noreply, state}
        else
          Logger.error("Max reconnect attempts reached for session #{state.id}")
          notify_channel(state, {:pty_exited, state.id, 1})
          {:stop, :connection_failed, state}
        end
    end
  end

  @impl true
  def handle_info({:pty_output, data}, state) do
    notify_channel(state, {:pty_output, state.id, data})
    buffer = [data | state.output_buffer]
    buffer = Enum.take(buffer, @pty_buffer_size)
    state = %{state | output_buffer: buffer}
    state = update_last_activity(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_exited, exit_code}, state) do
    Logger.info("PTY exited: session=#{state.id} code=#{exit_code}")
    notify_channel(state, {:pty_exited, state.id, exit_code})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:grpc_error, reason}, state) do
    Logger.error("gRPC error in debug session: #{inspect(reason)}")
    state = %{state | status: :reconnecting}
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_timeout, state) do
    now = DateTime.utc_now()
    idle_time = DateTime.diff(now, state.last_activity_at, :millisecond)

    if idle_time > @session_timeout_ms do
      Logger.info("Debug session timed out: #{state.id}")
      {:stop, :timeout, state}
    else
      schedule_timeout_check()
      {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Debug session terminating: session=#{state.id} reason=#{inspect(reason)}")

    if state.grpc_stream do
      GRPC.Stub.disconnect(state.grpc_channel)
    end

    :ok
  end

  defp establish_grpc_connection(state) do
    machine = state.machine
    grpc_endpoint = get_grpc_endpoint(machine)

    with {:ok, channel} <-
           GRPC.Stub.connect(grpc_endpoint, interceptors: [GRPC.Client.Interceptors.Logger]),
         request <- build_pty_request(state),
         {:ok, stream} <- Stub.attach_pty(channel, request) do
      {:ok, channel, stream}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_grpc_endpoint(machine) do
    region = machine.region || "lax"
    port = 50051

    case region do
      "lax" -> "localhost:#{port}"
      "ord" -> "localhost:#{port + 1}"
      "iad" -> "localhost:#{port + 2}"
      _ -> "localhost:#{port}"
    end
  end

  defp build_pty_request(state) do
    PTYRequest.new(
      machine_id: state.machine_id,
      shell: state.shell,
      cwd: state.cwd,
      rows: state.rows,
      cols: state.cols,
      env: Map.to_list(state.env)
    )
  end

  defp send_pty_input(state, data) do
    if state.grpc_stream do
      input = PTYInput.new(data: data)

      case GRPC.Stub.send_request(state.grpc_stream, input) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_connected}
    end
  end

  defp send_pty_resize(state, rows, cols) do
    if state.grpc_stream do
      resize = PTYResize.new(rows: rows, cols: cols)

      case GRPC.Stub.send_request(state.grpc_stream, resize) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_connected}
    end
  end

  defp read_pty_output(stream, session_pid) do
    case GRPC.Stub.recv(stream) do
      {:ok, %{data: data}} when is_binary(data) ->
        send(session_pid, {:pty_output, data})
        read_pty_output(stream, session_pid)

      {:ok, %{exit_code: code}} ->
        send(session_pid, {:pty_exited, code})

      {:error, reason} ->
        send(session_pid, {:grpc_error, reason})
    end
  rescue
    e ->
      Logger.error("Error reading PTY output: #{inspect(e)}")
      send(session_pid, {:grpc_error, e})
  end

  defp notify_channel(state, message) do
    if state.channel_pid && Process.alive?(state.channel_pid) do
      send(state.channel_pid, message)
    end
  end

  defp update_last_activity(state) do
    %{state | last_activity_at: DateTime.utc_now()}
  end

  defp schedule_timeout_check do
    Process.send_after(self(), :check_timeout, 60_000)
  end

  defp via_tuple(session_id) do
    {:via, Registry, {Orchestrator.DebugSessionRegistry, session_id}}
  end
end
