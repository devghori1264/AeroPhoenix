defmodule OrchestratorWeb.DebugChannel do
  use OrchestratorWeb, :channel
  require Logger
  alias Orchestrator.{Repo, Machine}
  alias OrchestratorWeb.DebugSession
  @max_session_duration_hours 8
  @heartbeat_interval_ms 30_000
  @metric_push_interval_ms 1_000
  def join("debug:shell:" <> machine_id, payload, socket) do
    with {:ok, machine} <- get_machine(machine_id),
         :ok <- authorize_debug_access(socket, machine),
         {:ok, session} <- create_debug_session(machine, payload, socket) do
      socket =
        socket
        |> assign(:machine_id, machine_id)
        |> assign(:machine, machine)
        |> assign(:session_id, session.id)
        |> assign(:session, session)
        |> assign(:mode, "shell")
        |> assign(:pty_size, {payload["rows"] || 24, payload["cols"] || 80})

      schedule_heartbeat()

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "machine:#{machine_id}",
        {:debug_session_started, %{session_id: session.id, user: get_user(socket)}}
      )

      Logger.info("Debug shell session started: machine=#{machine_id} session=#{session.id}")
      {:ok, %{session_id: session.id, machine: format_machine(machine)}, socket}
    else
      {:error, :not_found} ->
        {:error, %{reason: "Machine not found"}}

      {:error, :unauthorized} ->
        {:error, %{reason: "Unauthorized access"}}

      {:error, reason} ->
        Logger.error("Failed to join debug channel: #{inspect(reason)}")
        {:error, %{reason: "Failed to create debug session"}}
    end
  end

  def join("debug:inspect:" <> machine_id, _payload, socket) do
    with {:ok, machine} <- get_machine(machine_id),
         :ok <- authorize_debug_access(socket, machine) do
      socket =
        socket
        |> assign(:machine_id, machine_id)
        |> assign(:machine, machine)
        |> assign(:mode, "inspect")

      schedule_metric_push()
      {:ok, %{machine: format_machine(machine)}, socket}
    else
      {:error, :not_found} ->
        {:error, %{reason: "Machine not found"}}

      {:error, :unauthorized} ->
        {:error, %{reason: "Unauthorized access"}}
    end
  end

  def join("debug:logs:" <> machine_id, payload, socket) do
    with {:ok, machine} <- get_machine(machine_id),
         :ok <- authorize_debug_access(socket, machine) do
      socket =
        socket
        |> assign(:machine_id, machine_id)
        |> assign(:machine, machine)
        |> assign(:mode, "logs")
        |> assign(:log_filters, parse_log_filters(payload))

      subscribe_to_logs(machine_id, socket.assigns.log_filters)
      {:ok, %{machine: format_machine(machine)}, socket}
    else
      {:error, :not_found} ->
        {:error, %{reason: "Machine not found"}}

      {:error, :unauthorized} ->
        {:error, %{reason: "Unauthorized access"}}
    end
  end

  def handle_in("input", %{"data" => data}, socket) when socket.assigns.mode == "shell" do
    session = socket.assigns.session

    case DebugSession.send_input(session, data) do
      :ok ->
        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.error("Failed to send PTY input: #{inspect(reason)}")
        {:reply, {:error, %{reason: "Failed to send input"}}, socket}
    end
  end

  def handle_in("resize", %{"rows" => rows, "cols" => cols}, socket)
      when socket.assigns.mode == "shell" do
    session = socket.assigns.session

    case DebugSession.resize(session, rows, cols) do
      :ok ->
        socket = assign(socket, :pty_size, {rows, cols})
        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.error("Failed to resize PTY: #{inspect(reason)}")
        {:reply, {:error, %{reason: "Failed to resize terminal"}}, socket}
    end
  end

  def handle_in("inspect." <> command, params, socket) when socket.assigns.mode == "inspect" do
    machine = socket.assigns.machine

    result =
      case command do
        "metrics" ->
          fetch_machine_metrics(machine)

        "threads" ->
          fetch_machine_threads(machine, params)

        "network" ->
          fetch_machine_network(machine, params)

        "fds" ->
          fetch_machine_fds(machine, params)

        "fsm" ->
          fetch_fsm_state(machine)

        _ ->
          {:error, :unknown_command}
      end

    case result do
      {:ok, data} ->
        {:reply, {:ok, data}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("debug." <> command, params, socket) do
    machine_id = socket.assigns.machine_id

    result =
      case command do
        "set_breakpoint" ->
          set_fsm_breakpoint(machine_id, params["state"], params["condition"])

        "remove_breakpoint" ->
          remove_fsm_breakpoint(machine_id, params["state"])

        "continue" ->
          continue_fsm_execution(machine_id)

        "step" ->
          step_fsm_execution(machine_id)

        _ ->
          {:error, :unknown_command}
      end

    case result do
      :ok ->
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_info({:pty_output, session_id, data}, socket) do
    if socket.assigns[:session_id] == session_id do
      push(socket, "output", %{data: data})
    end

    {:noreply, socket}
  end

  def handle_info({:pty_exited, session_id, exit_code}, socket) do
    if socket.assigns[:session_id] == session_id do
      push(socket, "exited", %{exit_code: exit_code})
      Logger.info("PTY session exited: session=#{session_id} code=#{exit_code}")
    end

    {:noreply, socket}
  end

  def handle_info(:heartbeat, socket) do
    push(socket, "heartbeat", %{timestamp: System.system_time(:millisecond)})
    session = socket.assigns[:session]

    if session && session_expired?(session) do
      Logger.warning("Debug session expired: #{session.id}")
      push(socket, "session_expired", %{})
      {:stop, :normal, socket}
    else
      schedule_heartbeat()
      {:noreply, socket}
    end
  end

  def handle_info(:push_metrics, socket) when socket.assigns.mode == "inspect" do
    machine = socket.assigns.machine

    case fetch_machine_metrics(machine) do
      {:ok, metrics} ->
        push(socket, "metrics", metrics)
    end

    schedule_metric_push()
    {:noreply, socket}
  end

  def handle_info({:log_message, log_entry}, socket) when socket.assigns.mode == "logs" do
    if passes_filters?(log_entry, socket.assigns.log_filters) do
      push(socket, "log", format_log_entry(log_entry))
    end

    {:noreply, socket}
  end

  def handle_info({:fsm_state_changed, machine_id, from_state, to_state, event}, socket) do
    if socket.assigns.machine_id == machine_id do
      push(socket, "fsm.state_changed", %{
        from: from_state,
        to: to_state,
        event: event,
        timestamp: DateTime.utc_now()
      })
    end

    {:noreply, socket}
  end

  def handle_info({:fsm_breakpoint_hit, machine_id, state, context}, socket) do
    if socket.assigns.machine_id == machine_id do
      push(socket, "debug.breakpoint_hit", %{
        state: state,
        context: context,
        timestamp: DateTime.utc_now()
      })
    end

    {:noreply, socket}
  end

  def terminate(reason, socket) do
    Logger.info(
      "Debug channel terminated: reason=#{inspect(reason)} machine=#{socket.assigns[:machine_id]}"
    )

    if session = socket.assigns[:session] do
      DebugSession.terminate(session)
    end

    if machine_id = socket.assigns[:machine_id] do
      Phoenix.PubSub.unsubscribe(Orchestrator.PubSub, "machine:#{machine_id}")
    end

    :ok
  end

  defp get_machine(machine_id) do
    case Repo.get(Machine, machine_id) do
      nil -> {:error, :not_found}
      machine -> {:ok, machine}
    end
  end

  defp authorize_debug_access(_socket, _machine) do
    :ok
  end

  defp create_debug_session(machine, payload, socket) do
    session_params = %{
      machine_id: machine.id,
      user: get_user(socket),
      shell: payload["shell"] || "/bin/bash",
      cwd: payload["cwd"] || "/root",
      rows: payload["rows"] || 24,
      cols: payload["cols"] || 80,
      env: payload["env"] || %{},
      channel_pid: self()
    }

    DebugSession.create(session_params)
  end

  defp get_user(socket) do
    socket.assigns[:current_user] || "anonymous"
  end

  defp format_machine(machine) do
    %{
      id: machine.id,
      name: machine.name,
      region: machine.region,
      status: machine.status,
      metadata: machine.metadata
    }
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  defp schedule_metric_push do
    Process.send_after(self(), :push_metrics, @metric_push_interval_ms)
  end

  defp session_expired?(session) do
    created_at = session.created_at
    max_duration = @max_session_duration_hours * 3600
    DateTime.diff(DateTime.utc_now(), created_at, :second) > max_duration
  end

  defp parse_log_filters(payload) do
    %{
      level: payload["level"],
      filter: payload["filter"],
      since: payload["since"]
    }
  end

  defp subscribe_to_logs(_machine_id, _filters) do
    :ok
  end

  defp passes_filters?(log_entry, filters) do
    level_match =
      if filters.level do
        log_level_value(log_entry.level) >= log_level_value(filters.level)
      else
        true
      end

    pattern_match =
      if filters.filter do
        String.contains?(log_entry.message, filters.filter)
      else
        true
      end

    level_match && pattern_match
  end

  defp log_level_value(level) do
    case level do
      "TRACE" -> 0
      "DEBUG" -> 1
      "INFO" -> 2
      "WARN" -> 3
      "ERROR" -> 4
      "FATAL" -> 5
      _ -> 0
    end
  end

  defp format_log_entry(entry) do
    %{
      timestamp: entry.timestamp,
      level: entry.level,
      message: entry.message,
      source: entry.source,
      fields: entry.fields || %{}
    }
  end

  defp fetch_machine_metrics(_machine) do
    {:ok,
     %{
       cpu: %{usage_percent: :rand.uniform() * 50, cores: 2},
       memory: %{rss_bytes: 1024 * 1024 * 256, vsz_bytes: 1024 * 1024 * 512},
       io: %{read_bytes: 1024 * 1024 * 100, write_bytes: 1024 * 1024 * 50},
       threads: %{count: 8, running: 1, sleeping: 7}
     }}
  end

  defp fetch_machine_threads(_machine, params) do
    _include_stacks = params["stacks"] == true

    threads = [
      %{tid: 1, name: "main", state: "S", cpu_percent: 2.5},
      %{tid: 2, name: "worker-1", state: "R", cpu_percent: 12.3},
      %{tid: 3, name: "worker-2", state: "S", cpu_percent: 0.5}
    ]

    {:ok, %{threads: threads}}
  end

  defp fetch_machine_network(_machine, _params) do
    connections = [
      %{
        protocol: "tcp",
        local_addr: "0.0.0.0",
        local_port: 8080,
        remote_addr: "0.0.0.0",
        remote_port: 0,
        state: "LISTEN"
      }
    ]

    {:ok, %{connections: connections}}
  end

  defp fetch_machine_fds(_machine, _params) do
    fds = [
      %{fd: 0, type: "file", target: "/dev/stdin"},
      %{fd: 1, type: "file", target: "/dev/stdout"},
      %{fd: 2, type: "file", target: "/dev/stderr"}
    ]

    {:ok, %{file_descriptors: fds}}
  end

  defp fetch_fsm_state(machine) do
    {:ok,
     %{
       current_state: machine.status,
       transitions: [],
       breakpoints: []
     }}
  end

  defp set_fsm_breakpoint(machine_id, state, _condition) do
    Logger.info("Setting FSM breakpoint: machine=#{machine_id} state=#{state}")
    :ok
  end

  defp remove_fsm_breakpoint(machine_id, state) do
    Logger.info("Removing FSM breakpoint: machine=#{machine_id} state=#{state}")
    :ok
  end

  defp continue_fsm_execution(machine_id) do
    Logger.info("Continuing FSM execution: machine=#{machine_id}")
    :ok
  end

  defp step_fsm_execution(machine_id) do
    Logger.info("Stepping FSM execution: machine=#{machine_id}")
    :ok
  end
end
