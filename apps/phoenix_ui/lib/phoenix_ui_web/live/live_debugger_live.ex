defmodule PhoenixUiWeb.LiveDebuggerLive do
  use PhoenixUiWeb, :live_view
  require Logger

  @impl true
  def mount(%{"machine_id" => machine_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "pty:#{machine_id}")

      case start_pty_session(machine_id, self()) do
        {:ok, pty_pid} ->
          {:ok,
           socket
           |> assign(:machine_id, machine_id)
           |> assign(:pty_pid, pty_pid)
           |> assign(:terminal_output, [])
           |> assign(:connected, true)}

        {:error, reason} ->
          {:ok,
           socket
           |> assign(:machine_id, machine_id)
           |> assign(:pty_pid, nil)
           |> assign(:terminal_output, ["Error starting PTY: #{inspect(reason)}"])
           |> assign(:connected, false)}
      end
    else
      {:ok,
       socket
       |> assign(:machine_id, machine_id)
       |> assign(:pty_pid, nil)
       |> assign(:terminal_output, [])
       |> assign(:connected, false)}
    end
  end

  @impl true
  def handle_event("terminal_input", %{"data" => data}, socket) do
    case socket.assigns.pty_pid do
      nil ->
        {:noreply, socket}

      pty_pid ->
        Orchestrator.Debugger.PTY.send_input(pty_pid, data)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("terminal_resize", %{"rows" => rows, "cols" => cols}, socket) do
    case socket.assigns.pty_pid do
      nil ->
        {:noreply, socket}

      pty_pid ->
        Orchestrator.Debugger.PTY.resize(pty_pid, rows, cols)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_signal", %{"signal" => signal}, socket) do
    case socket.assigns.pty_pid do
      nil ->
        {:noreply, socket}

      pty_pid ->
        signal_atom = String.to_existing_atom(signal)
        Orchestrator.Debugger.PTY.send_signal(pty_pid, signal_atom)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:pty_output, data}, socket) do
    new_output = socket.assigns.terminal_output ++ [data]

    new_output = Enum.take(new_output, -1000)

    {:noreply,
     socket
     |> assign(:terminal_output, new_output)
     |> push_event("terminal_data", %{data: data})}
  end

  @impl true
  def handle_info({:pty_exited, status}, socket) do
    Logger.info("PTY exited", machine_id: socket.assigns.machine_id, status: status)

    {:noreply,
     socket
     |> assign(:connected, false)
     |> push_event("terminal_data", %{data: "\r\n[PTY session ended with status #{status}]\r\n"})}
  end

  @impl true
  def handle_info({:pty_crashed, reason}, socket) do
    Logger.error("PTY crashed", machine_id: socket.assigns.machine_id, reason: reason)

    {:noreply,
     socket
     |> assign(:connected, false)
     |> push_event("terminal_data", %{data: "\r\n[PTY session crashed: #{inspect(reason)}]\r\n"})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-gray-900">
      <div class="flex items-center justify-between px-6 py-4 bg-gray-800 border-b border-gray-700">
        <div>
          <h1 class="text-2xl font-bold text-white">Live Debugger</h1>
          <p class="text-sm text-gray-400">Machine: {@machine_id}</p>
        </div>

        <div class="flex gap-2">
          <%= if @connected do %>
            <span class="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-green-400 bg-green-900/20 border border-green-500/30 rounded-lg">
              <span class="w-2 h-2 bg-green-400 rounded-full animate-pulse"></span> Connected
            </span>
          <% else %>
            <span class="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-red-400 bg-red-900/20 border border-red-500/30 rounded-lg">
              <span class="w-2 h-2 bg-red-400 rounded-full"></span> Disconnected
            </span>
          <% end %>

          <button
            phx-click="send_signal"
            phx-value-signal="int"
            class="px-3 py-1.5 text-sm font-medium text-white bg-yellow-600 hover:bg-yellow-700 rounded-lg transition-colors"
            disabled={!@connected}
          >
            Send SIGINT (Ctrl+C)
          </button>

          <button
            phx-click="send_signal"
            phx-value-signal="term"
            class="px-3 py-1.5 text-sm font-medium text-white bg-red-600 hover:bg-red-700 rounded-lg transition-colors"
            disabled={!@connected}
          >
            Send SIGTERM
          </button>
        </div>
      </div>

      <div class="flex-1 p-4">
        <div
          id="xterm-container"
          phx-hook="XTerminal"
          phx-update="ignore"
          class="w-full h-full bg-black rounded-lg shadow-2xl"
        >
        </div>
      </div>

      <div class="px-6 py-3 bg-gray-800 border-t border-gray-700">
        <p class="text-xs text-gray-500">
          Use xterm.js for interactive shell. Press Ctrl+C to interrupt, Ctrl+D to exit.
        </p>
      </div>
    </div>
    """
  end

  defp start_pty_session(machine_id, session_pid) do
    opts = [
      shell: "/bin/bash",
      env: %{},
      cwd: "/root",
      size: {24, 80}
    ]

    Orchestrator.Debugger.PTY.start_link(machine_id, session_pid, opts)
  end
end
