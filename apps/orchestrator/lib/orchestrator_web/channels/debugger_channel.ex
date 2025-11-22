defmodule OrchestratorWeb.DebuggerChannel do
  use OrchestratorWeb, :channel
  require Logger
  alias Orchestrator.Debugger.{Session, PTY, ProcessInspector, NetworkCapture, FSBrowser}
  alias Orchestrator.MachineFSM
  @impl true
  def join("debug:" <> machine_id, params, socket) do
    Logger.info("Joining debugger channel",
      machine_id: machine_id,
      user_id: socket.assigns.user_id
    )

    case verify_machine_access(machine_id, socket.assigns.user_id) do
      :ok ->
        session_opts = [
          user_id: socket.assigns.user_id,
          mode: Map.get(params, "mode", "shell") |> String.to_atom(),
          record: Map.get(params, "record", false)
        ]

        case Session.start_session(machine_id, session_opts) do
          {:ok, session_id} ->
            case Session.attach(session_id, self()) do
              {:ok, initial_state} ->
                socket =
                  socket
                  |> assign(:machine_id, machine_id)
                  |> assign(:session_id, session_id)
                  |> assign(:mode, initial_state.mode)

                {:ok, %{session_id: session_id, state: initial_state}, socket}

              {:error, reason} ->
                {:error, %{reason: inspect(reason)}}
            end

          {:error, reason} ->
            {:error, %{reason: inspect(reason)}}
        end

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  @impl true
  def handle_in("shell.attach", %{"options" => opts}, socket) do
    mode = Map.get(opts, "mode", "shell") |> String.to_atom()

    case Session.switch_mode(socket.assigns.session_id, mode) do
      :ok ->
        {:reply, {:ok, %{status: "attached", mode: mode}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("shell.input", %{"data" => data}, socket) do
    case Session.send_input(socket.assigns.session_id, data) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        push(socket, "error", %{message: "Failed to send input", reason: inspect(reason)})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_in("shell.resize", %{"rows" => rows, "cols" => cols}, socket) do
    {:reply, {:ok, %{rows: rows, cols: cols}}, socket}
  end

  @impl true
  def handle_in("inspect.metrics", _params, socket) do
    case Session.get_metrics(socket.assigns.session_id) do
      {:ok, metrics} ->
        {:reply, {:ok, metrics}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("inspect.threads", _params, socket) do
    case ProcessInspector.get_thread_info(socket.assigns.machine_id) do
      {:ok, threads} ->
        {:reply, {:ok, %{threads: threads}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("inspect.fds", _params, socket) do
    case ProcessInspector.list_file_descriptors(socket.assigns.machine_id) do
      {:ok, fds} ->
        {:reply, {:ok, %{file_descriptors: fds}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("inspect.network", _params, socket) do
    case ProcessInspector.get_network_connections(socket.assigns.machine_id) do
      {:ok, connections} ->
        {:reply, {:ok, %{connections: connections}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("capture.start", params, socket) do
    opts = [
      interface: Map.get(params, "interface", "eth0"),
      filter: Map.get(params, "filter"),
      max_packets: Map.get(params, "max_packets", 10_000),
      protocols: Map.get(params, "protocols", ["tcp", "udp"]) |> Enum.map(&String.to_atom/1)
    ]

    case Session.start_capture(socket.assigns.session_id, opts) do
      :ok ->
        {:reply, {:ok, %{status: "capturing"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("capture.stop", _params, socket) do
    case Session.stop_capture(socket.assigns.session_id) do
      {:ok, packets} ->
        packet_data = Enum.map(packets, &serialize_packet/1)
        {:reply, {:ok, %{packets: packet_data}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("capture.export", %{"path" => path}, socket) do
    {:reply, {:ok, %{path: path}}, socket}
  end

  @impl true
  def handle_in("fs.list", %{"path" => path} = params, socket) do
    opts = [
      recursive: Map.get(params, "recursive", false),
      max_depth: Map.get(params, "max_depth", 1),
      include_hidden: Map.get(params, "include_hidden", false),
      sort_by: Map.get(params, "sort_by", "name") |> String.to_atom()
    ]

    case Session.list_files(socket.assigns.session_id, path) do
      {:ok, files} ->
        {:reply, {:ok, %{files: files}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("fs.read", %{"path" => path} = params, socket) do
    opts = [
      max_size: Map.get(params, "max_size", 10 * 1024 * 1024),
      encoding: Map.get(params, "encoding", "auto") |> String.to_atom()
    ]

    case Session.read_file(socket.assigns.session_id, path) do
      {:ok, content} ->
        {:reply, {:ok, %{content: content}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("fs.search", %{"path" => path, "pattern" => pattern} = params, socket) do
    opts = [
      max_depth: Map.get(params, "max_depth", 5),
      case_sensitive: Map.get(params, "case_sensitive", false),
      regex: Map.get(params, "regex", false)
    ]

    case FSBrowser.search_files(socket.assigns.machine_id, path, pattern, opts) do
      {:ok, results} ->
        {:reply, {:ok, %{results: results}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("fs.grep", %{"path" => path, "query" => query} = params, socket) do
    opts = [
      max_depth: Map.get(params, "max_depth", 3),
      file_pattern: Map.get(params, "file_pattern", "*"),
      case_sensitive: Map.get(params, "case_sensitive", false),
      regex: Map.get(params, "regex", false)
    ]

    case FSBrowser.search_content(socket.assigns.machine_id, path, query, opts) do
      {:ok, results} ->
        {:reply, {:ok, %{results: results}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("fs.watch", %{"path" => path}, socket) do
    case FSBrowser.watch_path(socket.assigns.machine_id, path, self()) do
      {:ok, ref} ->
        {:reply, {:ok, %{watch_id: inspect(ref)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("debug.breakpoint", %{"state" => state, "action" => "set"}, socket) do
    case Session.set_breakpoint(socket.assigns.session_id, state) do
      :ok ->
        {:reply, {:ok, %{breakpoint: state, status: "set"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("debug.breakpoint", %{"state" => state, "action" => "remove"}, socket) do
    case Session.remove_breakpoint(socket.assigns.session_id, state) do
      :ok ->
        {:reply, {:ok, %{breakpoint: state, status: "removed"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("debug.continue", _params, socket) do
    case Session.continue_execution(socket.assigns.session_id) do
      :ok ->
        {:reply, {:ok, %{status: "resumed"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("debug.state", _params, socket) do
    case MachineFSM.get_state(socket.assigns.machine_id) do
      {:ok, fsm_state} ->
        {:reply, {:ok, %{state: fsm_state}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("ping", _params, socket) do
    {:reply, {:ok, %{pong: true, timestamp: DateTime.utc_now()}}, socket}
  end

  @impl true
  def handle_in(event, params, socket) do
    Logger.warn("Unknown debugger event",
      event: event,
      params: inspect(params),
      session_id: socket.assigns.session_id
    )

    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl true
  def handle_info({:debug_session, session_id, message}, socket) do
    case message do
      {:output, data} ->
        push(socket, "shell.output", %{data: data})

      {:mode_changed, new_mode} ->
        socket = assign(socket, :mode, new_mode)
        push(socket, "session.mode_changed", %{mode: new_mode})

      {:breakpoint_set, state} ->
        push(socket, "debug.breakpoint_hit", %{state: state})

      {:breakpoint_removed, state} ->
        push(socket, "debug.breakpoint_removed", %{state: state})

      :execution_continued ->
        push(socket, "debug.execution_continued", %{})

      {:metrics_updated, metrics} ->
        push(socket, "inspect.metrics", metrics)

      :capture_started ->
        push(socket, "capture.started", %{})

      {:capture_stopped, packet_count} ->
        push(socket, "capture.stopped", %{packet_count: packet_count})

      other ->
        Logger.debug("Unhandled session message",
          session_id: session_id,
          message: inspect(other)
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:fs_change, ref, path, events}, socket) do
    push(socket, "fs.changed", %{
      watch_id: inspect(ref),
      path: path,
      events: events
    })

    {:noreply, socket}
  end

  @impl true
  def terminate(reason, socket) do
    Logger.info("Debugger channel terminated",
      session_id: socket.assigns.session_id,
      reason: inspect(reason)
    )

    Session.detach(socket.assigns.session_id, self())
    :ok
  end

  defp verify_machine_access(machine_id, user_id) do
    Logger.debug("Verifying machine access",
      machine_id: machine_id,
      user_id: user_id
    )

    :ok
  end

  defp serialize_packet(packet) do
    %{
      timestamp: DateTime.to_iso8601(packet.timestamp),
      source_ip: packet.source_ip,
      dest_ip: packet.dest_ip,
      source_port: packet.source_port,
      dest_port: packet.dest_port,
      protocol: packet.protocol,
      length: packet.length,
      flags: packet.flags,
      dissected: packet.dissected
    }
  end
end
