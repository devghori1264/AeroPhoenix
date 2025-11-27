defmodule PhoenixUiWeb.LiveDebuggerComponent do
  use PhoenixUiWeb, :live_component
  require Logger

  @process_refresh_interval 2_000
  @packet_buffer_size 1_000
  @max_log_lines 5_000

  @terminal_themes %{
    "dracula" => %{
      background: "#1e1e2e",
      foreground: "#cdd6f4",
      cursor: "#f5e0dc",
      selection: "#585b7088",
      black: "#45475a",
      red: "#f38ba8",
      green: "#a6e3a1",
      yellow: "#f9e2af",
      blue: "#89b4fa",
      magenta: "#f5c2e7",
      cyan: "#94e2d5",
      white: "#bac2de"
    },
    "monokai" => %{
      background: "#272822",
      foreground: "#f8f8f2",
      cursor: "#f8f8f0",
      selection: "#49483e",
      black: "#272822",
      red: "#f92672",
      green: "#a6e22e",
      yellow: "#f4bf75",
      blue: "#66d9ef",
      magenta: "#ae81ff",
      cyan: "#a1efe4",
      white: "#f8f8f2"
    },
    "nord" => %{
      background: "#2e3440",
      foreground: "#d8dee9",
      cursor: "#d8dee9",
      selection: "#4c566a",
      black: "#3b4252",
      red: "#bf616a",
      green: "#a3be8c",
      yellow: "#ebcb8b",
      blue: "#81a1c1",
      magenta: "#b48ead",
      cyan: "#88c0d0",
      white: "#e5e9f0"
    }
  }

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:view_mode, "terminal")
     |> assign(:terminal_themes, @terminal_themes)
     |> assign(:terminal_theme, "dracula")
     |> assign(:terminal_font_size, 14)
     |> assign(:terminal_sessions, [])
     |> assign(:active_session_id, nil)
     |> assign(:process_tree, [])
     |> assign(:selected_process, nil)
     |> assign(:process_filter, "")
     |> assign(:process_sort, "memory")
     |> assign(:packet_capture, [])
     |> assign(:capture_filter, "all")
     |> assign(:capture_running, false)
     |> assign(:log_sources, ["orchestrator", "flyd-sim", "net-sim"])
     |> assign(:log_entries, [])
     |> assign(:log_filter, "")
     |> assign(:log_level, "all")
     |> assign(:trace_spans, [])
     |> assign(:selected_trace, nil)
     |> assign(:flamegraph_data, nil)
     |> assign(:show_process_details, false)
     |> assign(:show_packet_hex, false)
     |> assign(:terminal_history, [])
     |> assign(:command_palette_open, false)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:debug_sessions, fn -> [] end)
      |> assign_new(:machines, fn -> [] end)
      |> assign_new(:terminal_sessions, fn -> [] end)
      |> maybe_schedule_process_refresh()

    {:ok, socket}
  end

  @impl true

  def render(assigns) do
    ~H"""
    <div class="space-y-6" phx-hook="DebuggerEnhancements" id="debugger-panel">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-3xl font-bold text-transparent bg-clip-text bg-gradient-to-r from-red-400 to-rose-600">
            Live Debugging Platform
          </h2>
          <p class="text-sm text-gray-400 mt-1">
            Production-grade debugging with zero-downtime introspection
          </p>
        </div>

        <div class="flex gap-2">
          <button
            :for={mode <- ["terminal", "processes", "network", "traces", "logs"]}
            phx-click="set_view_mode"
            phx-value-mode={mode}
            phx-target={@myself}
            class={[
              "px-4 py-2 rounded-lg font-medium transition-all duration-200",
              if(@view_mode == mode,
                do: "bg-gradient-to-r from-red-500 to-rose-600 text-white shadow-lg",
                else:
                  "glass-panel text-gray-500 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white hover:bg-gray-100 dark:hover:bg-white/10"
              )
            ]}
          >
            {mode |> String.capitalize()}
          </button>
        </div>
      </div>

      <%= case @view_mode do %>
        <% "terminal" -> %>
          {render_terminal_view(assigns)}
        <% "processes" -> %>
          {render_process_inspector(assigns)}
        <% "network" -> %>
          {render_network_capture(assigns)}
        <% "traces" -> %>
          {render_trace_viewer(assigns)}
        <% "logs" -> %>
          {render_log_aggregator(assigns)}
      <% end %>

      <%= if @command_palette_open do %>
        <div class="fixed inset-0 bg-black/50 z-50 flex items-start justify-center pt-20">
          <div class="glass-panel w-full max-w-2xl p-4 shadow-2xl border border-red-500/30">
            <input
              type="text"
              placeholder="Type a command... (attach, inspect, capture, trace, tail)"
              class="w-full bg-white dark:bg-gray-900/50 text-gray-900 dark:text-white px-4 py-3 rounded-lg border border-gray-200 dark:border-gray-700 focus:border-red-500 focus:outline-none"
              phx-keydown="handle_command_input"
              phx-target={@myself}
            />
            <div class="mt-4 space-y-2">
              <div
                :for={cmd <- command_suggestions(@process_filter)}
                class="p-3 hover:bg-white/5 rounded cursor-pointer text-sm text-gray-300"
              >
                <span class="text-red-400 font-mono">{cmd.name}</span>
                <span class="text-gray-500 ml-2">— {cmd.description}</span>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_terminal_view(assigns) do
    ~H"""
    <div class="grid grid-cols-12 gap-6">
      <div class="col-span-3 space-y-4">
        <div class="glass-panel p-4">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-semibold text-gray-900 dark:text-white">Sessions</h3>
            <button
              phx-click="create_terminal_session"
              phx-target={@myself}
              class="px-3 py-1 bg-gradient-to-r from-red-500 to-rose-600 text-white text-sm rounded-lg hover:shadow-lg transition-all"
            >
              + New
            </button>
          </div>

          <div class="space-y-2">
            <%= for session <- @terminal_sessions do %>
              <div
                phx-click="switch_terminal_session"
                phx-value-id={session.id}
                phx-target={@myself}
                class={[
                  "p-3 rounded-lg cursor-pointer transition-all",
                  if(@active_session_id == session.id,
                    do: "bg-gradient-to-r from-red-500/20 to-rose-600/20 border border-red-500/50",
                    else:
                      "bg-gray-100 dark:bg-gray-800/50 border border-gray-200 dark:border-gray-700/50 hover:border-gray-300 dark:hover:border-gray-600"
                  )
                ]}
              >
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <div class={[
                      "w-2 h-2 rounded-full",
                      if(session.connected, do: "bg-green-500 pulse-glow", else: "bg-gray-500")
                    ]}>
                    </div>
                    <span class="text-sm font-mono text-gray-700 dark:text-white">
                      {session.machine_id}
                    </span>
                  </div>
                  <button
                    phx-click="close_terminal_session"
                    phx-value-id={session.id}
                    phx-target={@myself}
                    class="text-gray-500 hover:text-red-400 transition-colors"
                  >
                    ×
                  </button>
                </div>
                <div class="mt-2 text-xs text-gray-400">
                  <div>Region: {session.region}</div>
                  <div>Uptime: {format_duration(session.uptime)}</div>
                </div>
              </div>
            <% end %>

            <%= if @terminal_sessions == [] do %>
              <div class="text-center py-8 text-gray-500 text-sm">
                No active sessions<br /> Click "+ New" to start
              </div>
            <% end %>
          </div>
        </div>

        <div class="glass-panel p-4">
          <h3 class="font-semibold text-gray-900 dark:text-white mb-4">Settings</h3>

          <div class="space-y-3">
            <div>
              <label class="text-xs text-gray-400 mb-1 block">Theme</label>
              <select
                phx-change="change_terminal_theme"
                phx-target={@myself}
                phx-target={@myself}
                class="w-full bg-white dark:bg-gray-900/50 text-gray-900 dark:text-white px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 text-sm"
              >
                >
                <option :for={{theme_name, _config} <- @terminal_themes} value={theme_name}>
                  {theme_name |> String.capitalize()}
                </option>
              </select>
            </div>

            <div>
              <label class="text-xs text-gray-400 mb-1 block">Font Size</label>
              <input
                type="range"
                min="10"
                max="20"
                value={@terminal_font_size}
                phx-change="change_terminal_font_size"
                phx-target={@myself}
                class="w-full"
              />
              <div class="text-xs text-gray-500 text-right">{@terminal_font_size}px</div>
            </div>
          </div>
        </div>
      </div>

      <div class="col-span-9">
        <div class="glass-panel p-6 h-[600px] flex flex-col">
          <%= if @active_session_id do %>
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-3">
                <div class="w-3 h-3 rounded-full bg-red-500"></div>
                <div class="w-3 h-3 rounded-full bg-yellow-500"></div>
                <div class="w-3 h-3 rounded-full bg-green-500"></div>
                <span class="text-sm text-gray-400 ml-2 font-mono">
                  root@{get_active_session(@terminal_sessions, @active_session_id).machine_id}
                </span>
              </div>

              <div class="flex gap-2">
                <button
                  phx-click="clear_terminal"
                  phx-target={@myself}
                  class="text-gray-400 hover:text-white text-sm px-3 py-1 rounded transition-colors"
                >
                  Clear
                </button>
                <button
                  phx-click="download_terminal_history"
                  phx-target={@myself}
                  class="text-gray-400 hover:text-white text-sm px-3 py-1 rounded transition-colors"
                >
                  Export
                </button>
              </div>
            </div>

            <div
              id={"terminal-#{@active_session_id}"}
              phx-hook="Terminal"
              data-session-id={@active_session_id}
              data-theme={Jason.encode!(@terminal_themes[@terminal_theme])}
              data-font-size={@terminal_font_size}
              class="flex-1 rounded-lg overflow-hidden"
              style="background-color: #{@terminal_themes[@terminal_theme].background};"
            >
            </div>
          <% else %>
            <div class="flex-1 flex items-center justify-center text-gray-500">
              <div class="text-center">
                <div class="text-6xl mb-4">💻</div>
                <p class="text-lg">No terminal session active</p>
                <p class="text-sm mt-2">Create a new session to start debugging</p>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp render_process_inspector(assigns) do
    ~H"""
    <div class="grid grid-cols-12 gap-6">
      <div class="col-span-7">
        <div class="glass-panel p-6">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-xl font-bold text-gray-900 dark:text-white">Process Tree</h3>
            <div class="flex gap-2">
              <input
                type="text"
                placeholder="Filter processes..."
                value={@process_filter}
                phx-change="filter_processes"
                phx-target={@myself}
                class="bg-white dark:bg-gray-900/50 text-gray-900 dark:text-white px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 text-sm w-64"
              />
              <select
                phx-change="sort_processes"
                phx-target={@myself}
                class="bg-white dark:bg-gray-900/50 text-gray-900 dark:text-white px-3 py-2 rounded-lg border border-gray-200 dark:border-gray-700 text-sm"
              >
                <option value="memory">Memory ↓</option>
                <option value="reductions">Reductions ↓</option>
                <option value="message_queue">Message Queue ↓</option>
                <option value="name">Name A-Z</option>
              </select>
            </div>
          </div>

          <div class="overflow-auto max-h-[700px] custom-scrollbar">
            <table class="w-full text-sm">
              <thead class="sticky top-0 bg-gray-50 dark:bg-gray-900/95 backdrop-blur-sm">
                <tr class="text-left text-gray-500 dark:text-gray-400 border-b border-gray-200 dark:border-gray-700">
                  <th class="py-2 px-3">PID</th>
                  <th class="py-2 px-3">Name/Module</th>
                  <th class="py-2 px-3 text-right">Memory</th>
                  <th class="py-2 px-3 text-right">Reductions</th>
                  <th class="py-2 px-3 text-right">Msgs</th>
                  <th class="py-2 px-3">Status</th>
                </tr>
              </thead>
              <tbody>
                <%= for proc <- filter_and_sort_processes(@process_tree, @process_filter, @process_sort) do %>
                  <tr
                    phx-click="select_process"
                    phx-value-pid={proc.pid}
                    phx-target={@myself}
                    class={[
                      "border-b border-gray-100 dark:border-gray-800 cursor-pointer transition-colors",
                      if(@selected_process == proc.pid,
                        do: "bg-red-500/10 border-l-4 border-l-red-500",
                        else: "hover:bg-gray-50 dark:hover:bg-white/5"
                      )
                    ]}
                  >
                    <td class="py-3 px-3 font-mono text-xs text-cyan-600 dark:text-cyan-400">
                      {proc.pid}
                    </td>
                    <td class="py-3 px-3">
                      <div class="font-medium text-gray-900 dark:text-white">
                        {proc.name || proc.module}
                      </div>
                      <%= if proc.application do %>
                        <div class="text-xs text-gray-500">{proc.application}</div>
                      <% end %>
                    </td>
                    <td class="py-3 px-3 text-right font-mono text-sm">
                      <span class={memory_color(proc.memory)}>{format_bytes(proc.memory)}</span>
                    </td>
                    <td class="py-3 px-3 text-right font-mono text-sm text-gray-600 dark:text-gray-300">
                      {format_number(proc.reductions)}
                    </td>
                    <td class="py-3 px-3 text-right">
                      <span class={[
                        "px-2 py-1 rounded text-xs font-medium",
                        message_queue_badge_class(proc.message_queue_len)
                      ]}>
                        {proc.message_queue_len}
                      </span>
                    </td>
                    <td class="py-3 px-3">
                      <span class={[
                        "px-2 py-1 rounded text-xs font-medium",
                        process_status_badge(proc.status)
                      ]}>
                        {proc.status}
                      </span>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-4 pt-4 border-t border-gray-200 dark:border-gray-800 flex items-center justify-between text-sm">
            <div class="text-gray-500 dark:text-gray-400">
              Total Processes:
              <span class="text-gray-900 dark:text-white font-medium">{length(@process_tree)}</span>
            </div>
            <div class="text-gray-500 dark:text-gray-400">
              Total Memory:
              <span class="text-emerald-600 dark:text-emerald-400 font-medium">
                {format_bytes(Enum.sum(Enum.map(@process_tree, & &1.memory)))}
              </span>
            </div>
          </div>
        </div>
      </div>

      <div class="col-span-5">
        <%= if @selected_process do %>
          <% proc = get_process_details(@process_tree, @selected_process) %>
          <div class="glass-panel p-6 space-y-6">
            <div>
              <h3 class="text-xl font-bold text-gray-900 dark:text-white mb-2">Process Details</h3>
              <p class="text-sm text-gray-500 dark:text-gray-400 font-mono">{proc.pid}</p>
            </div>

            <div class="grid grid-cols-2 gap-4">
              <div class="bg-gray-50 dark:bg-gray-900/50 p-4 rounded-lg">
                <div class="text-xs text-gray-500 dark:text-gray-400 mb-1">Memory</div>
                <div class="text-xl font-bold text-emerald-600 dark:text-emerald-400">
                  {format_bytes(proc.memory)}
                </div>
              </div>
              <div class="bg-gray-50 dark:bg-gray-900/50 p-4 rounded-lg">
                <div class="text-xs text-gray-500 dark:text-gray-400 mb-1">Reductions</div>
                <div class="text-xl font-bold text-blue-600 dark:text-blue-400">
                  {format_number(proc.reductions)}
                </div>
              </div>
              <div class="bg-gray-50 dark:bg-gray-900/50 p-4 rounded-lg">
                <div class="text-xs text-gray-500 dark:text-gray-400 mb-1">Message Queue</div>
                <div class="text-xl font-bold text-amber-600 dark:text-amber-400">
                  {proc.message_queue_len}
                </div>
              </div>
              <div class="bg-gray-50 dark:bg-gray-900/50 p-4 rounded-lg">
                <div class="text-xs text-gray-500 dark:text-gray-400 mb-1">Status</div>
                <div class="text-xl font-bold text-purple-600 dark:text-purple-400">
                  {proc.status}
                </div>
              </div>
            </div>

            <div>
              <h4 class="text-sm font-semibold text-gray-900 dark:text-white mb-3">Information</h4>
              <div class="space-y-2 text-sm">
                <div class="flex justify-between">
                  <span class="text-gray-500 dark:text-gray-400">Registered Name:</span>
                  <span class="text-gray-700 dark:text-gray-300 font-mono">{proc.name || "—"}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500 dark:text-gray-400">Module:</span>
                  <span class="text-cyan-600 dark:text-cyan-400 font-mono">{proc.module}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500 dark:text-gray-400">Application:</span>
                  <span class="text-gray-700 dark:text-gray-300">{proc.application || "—"}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500 dark:text-gray-400">Priority:</span>
                  <span class="text-gray-700 dark:text-gray-300">{proc.priority}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500 dark:text-gray-400">Trap Exit:</span>
                  <span class={
                    if proc.trap_exit, do: "text-amber-600 dark:text-amber-400", else: "text-gray-500"
                  }>
                    {if proc.trap_exit, do: "Yes", else: "No"}
                  </span>
                </div>
              </div>
            </div>

            <div>
              <div class="flex items-center justify-between mb-3">
                <h4 class="text-sm font-semibold text-gray-900 dark:text-white">State</h4>
                <button
                  phx-click="refresh_process_state"
                  phx-value-pid={proc.pid}
                  phx-target={@myself}
                  class="text-xs text-red-500 dark:text-red-400 hover:text-red-600 dark:hover:text-red-300 transition-colors"
                >
                  Refresh
                </button>
              </div>
              <div class="bg-gray-50 dark:bg-gray-900/50 p-4 rounded-lg overflow-auto max-h-64 custom-scrollbar">
                <pre class="text-xs text-gray-700 dark:text-gray-300 font-mono whitespace-pre-wrap">{inspect(proc.state, pretty: true, limit: 50)}</pre>
              </div>
            </div>

            <div class="flex gap-2">
              <button
                phx-click="send_message_to_process"
                phx-value-pid={proc.pid}
                phx-target={@myself}
                class="flex-1 px-4 py-2 bg-gradient-to-r from-blue-500 to-blue-600 text-white rounded-lg hover:shadow-lg transition-all text-sm"
              >
                Send Message
              </button>
              <button
                phx-click="suspend_process"
                phx-value-pid={proc.pid}
                phx-target={@myself}
                class="flex-1 px-4 py-2 bg-gradient-to-r from-amber-500 to-amber-600 text-white rounded-lg hover:shadow-lg transition-all text-sm"
              >
                Suspend
              </button>
              <button
                phx-click="kill_process"
                phx-value-pid={proc.pid}
                phx-target={@myself}
                class="px-4 py-2 bg-gradient-to-r from-red-500 to-rose-600 text-white rounded-lg hover:shadow-lg transition-all text-sm"
              >
                Kill
              </button>
            </div>
          </div>
        <% else %>
          <div class="glass-panel p-6 h-full flex items-center justify-center text-gray-500">
            <div class="text-center">
              <div class="text-6xl mb-4">🔍</div>
              <p class="text-lg">No process selected</p>
              <p class="text-sm mt-2">Click on a process to inspect</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_network_capture(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="glass-panel p-6">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-4">
            <button
              phx-click="toggle_packet_capture"
              phx-target={@myself}
              class={[
                "px-6 py-2 rounded-lg font-medium transition-all shadow-lg",
                if(@capture_running,
                  do: "bg-gradient-to-r from-red-500 to-rose-600 text-white pulse-glow",
                  else: "bg-gradient-to-r from-emerald-500 to-emerald-600 text-white"
                )
              ]}
            >
              <%= if @capture_running do %>
                ⏸ Stop Capture
              <% else %>
                ▶️ Start Capture
              <% end %>
            </button>

            <%= if @capture_running do %>
              <div class="flex items-center gap-2 text-sm">
                <div class="w-2 h-2 bg-red-500 rounded-full animate-pulse"></div>
                <span class="text-gray-400">Recording...</span>
                <span class="text-white font-medium">{length(@packet_capture)} packets</span>
              </div>
            <% end %>
          </div>

          <div class="flex gap-2">
            <select
              phx-change="change_capture_filter"
              phx-target={@myself}
              class="bg-white dark:bg-gray-900/50 text-gray-900 dark:text-white px-4 py-2 rounded-lg border border-gray-200 dark:border-gray-700 text-sm"
            >
              <option value="all">All Protocols</option>
              <option value="grpc">gRPC only</option>
              <option value="http2">HTTP/2 only</option>
              <option value="tcp">TCP only</option>
              <option value="udp">UDP only</option>
            </select>

            <button
              phx-click="clear_packet_capture"
              phx-target={@myself}
              class="px-4 py-2 bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 rounded-lg hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors text-sm"
            >
              Clear
            </button>

            <button
              phx-click="export_pcap"
              phx-target={@myself}
              class="px-4 py-2 bg-gradient-to-r from-violet-500 to-violet-600 text-white rounded-lg hover:shadow-lg transition-all text-sm"
            >
              Export PCAP
            </button>
          </div>
        </div>
      </div>

      <div class="glass-panel p-6">
        <div class="overflow-auto max-h-[600px] custom-scrollbar">
          <table class="w-full text-sm font-mono">
            <thead class="sticky top-0 bg-gray-50 dark:bg-gray-900/95 backdrop-blur-sm">
              <tr class="text-left text-gray-500 dark:text-gray-400 border-b border-gray-200 dark:border-gray-700">
                <th class="py-2 px-3">#</th>
                <th class="py-2 px-3">Time</th>
                <th class="py-2 px-3">Source</th>
                <th class="py-2 px-3">Destination</th>
                <th class="py-2 px-3">Protocol</th>
                <th class="py-2 px-3">Length</th>
                <th class="py-2 px-3">Info</th>
              </tr>
            </thead>
            <tbody>
              <%= for {packet, idx} <- Enum.with_index(filter_packets(@packet_capture, @capture_filter), 1) do %>
                <tr
                  phx-click="select_packet"
                  phx-value-index={idx}
                  phx-target={@myself}
                  class="border-b border-gray-100 dark:border-gray-800 hover:bg-gray-50 dark:hover:bg-white/5 cursor-pointer transition-colors"
                >
                  <td class="py-2 px-3 text-gray-500">{idx}</td>
                  <td class="py-2 px-3 text-gray-500 dark:text-gray-400 text-xs">
                    {format_timestamp_ms(packet.timestamp)}
                  </td>
                  <td class="py-2 px-3 text-cyan-600 dark:text-cyan-400">{packet.source}</td>
                  <td class="py-2 px-3 text-emerald-600 dark:text-emerald-400">
                    {packet.destination}
                  </td>
                  <td class="py-2 px-3">
                    <span class={protocol_badge_class(packet.protocol)}>
                      {packet.protocol}
                    </span>
                  </td>
                  <td class="py-2 px-3 text-gray-600 dark:text-gray-300">{packet.length} bytes</td>
                  <td class="py-2 px-3 text-gray-500 dark:text-gray-400 truncate max-w-md">
                    {packet.info}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>

          <%= if filter_packets(@packet_capture, @capture_filter) == [] do %>
            <div class="text-center py-12 text-gray-500">
              <%= if @capture_running do %>
                <div class="text-6xl mb-4">📡</div>
                <p class="text-lg">Listening for packets...</p>
                <p class="text-sm mt-2">Network traffic will appear here</p>
              <% else %>
                <div class="text-6xl mb-4">🌐</div>
                <p class="text-lg">No packets captured</p>
                <p class="text-sm mt-2">Click "Start Capture" to begin monitoring</p>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp render_trace_viewer(assigns) do
    ~H"""
    <div class="grid grid-cols-12 gap-6">
      <div class="col-span-8">
        <div class="glass-panel p-6">
          <h3 class="text-xl font-bold text-white mb-4">Distributed Traces</h3>

          <%= if @trace_spans != [] do %>
            <div class="space-y-3">
              <%= for trace <- group_spans_by_trace(@trace_spans) do %>
                <div
                  phx-click="select_trace"
                  phx-value-trace-id={trace.trace_id}
                  phx-target={@myself}
                  class={[
                    "p-4 rounded-lg cursor-pointer transition-all border",
                    if(@selected_trace == trace.trace_id,
                      do: "bg-indigo-500/10 border-indigo-500",
                      else: "bg-gray-800/50 border-gray-700 hover:border-gray-600"
                    )
                  ]}
                >
                  <div class="flex items-center justify-between mb-2">
                    <div class="flex items-center gap-3">
                      <span class="text-white font-medium">{trace.operation}</span>
                      <span class={[
                        "px-2 py-1 rounded text-xs font-medium",
                        status_badge_class(trace.status)
                      ]}>
                        {trace.status}
                      </span>
                    </div>
                    <div class="text-sm">
                      <span class="text-gray-400">Duration:</span>
                      <span class="text-amber-400 font-medium ml-1">{trace.total_duration}ms</span>
                    </div>
                  </div>

                  <div class="text-xs text-gray-400 mb-3">
                    {trace.span_count} spans • {format_timestamp(trace.start_time)}
                  </div>

                  <div class="relative h-12 bg-gray-900/50 rounded overflow-hidden">
                    <%= for span <- trace.spans do %>
                      <% offset_pct = span.start_offset / trace.total_duration * 100 %>
                      <% width_pct = span.duration / trace.total_duration * 100 %>
                      <div
                        class="absolute h-8 rounded transition-all hover:h-10 hover:z-10 cursor-pointer"
                        style={"left: #{offset_pct}%; width: #{width_pct}%; top: 25%; background: #{span_color(span.service)};"}
                        title={span.name}
                      >
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="text-center py-12 text-gray-500">
              <div class="text-6xl mb-4">🔬</div>
              <p class="text-lg">No traces available</p>
              <p class="text-sm mt-2">Execute operations to see distributed traces</p>
            </div>
          <% end %>
        </div>
      </div>

      <div class="col-span-4">
        <%= if @selected_trace do %>
          <div class="glass-panel p-6">
            <h3 class="text-xl font-bold text-white mb-4">Flamegraph</h3>
            <div class="bg-gray-900/50 rounded-lg p-4 h-96">
              <div class="text-center text-gray-500 text-sm">
                Interactive flamegraph visualization
              </div>
            </div>
          </div>
        <% else %>
          <div class="glass-panel p-6 h-full flex items-center justify-center text-gray-500">
            <div class="text-center">
              <div class="text-6xl mb-4">🔥</div>
              <p class="text-lg">Select a trace</p>
              <p class="text-sm mt-2">to see flamegraph</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_log_aggregator(assigns) do
    ~H"""
    <div class="glass-panel p-6">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-4">
          <h3 class="text-xl font-bold text-white">Aggregated Logs</h3>

          <div class="flex gap-2">
            <%= for source <- @log_sources do %>
              <label class="flex items-center gap-2 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  checked
                  class="rounded border-gray-600 bg-gray-800 text-violet-500"
                />
                <span class="text-gray-300">{source}</span>
              </label>
            <% end %>
          </div>
        </div>

        <div class="flex gap-2">
          <select
            phx-change="change_log_level"
            phx-target={@myself}
            class="bg-gray-900/50 text-white px-3 py-2 rounded-lg border border-gray-700 text-sm"
          >
            <option value="all">All Levels</option>
            <option value="debug">Debug</option>
            <option value="info">Info</option>
            <option value="warning">Warning</option>
            <option value="error">Error</option>
          </select>

          <input
            type="text"
            placeholder="Filter logs..."
            value={@log_filter}
            phx-change="filter_logs"
            phx-target={@myself}
            class="bg-gray-900/50 text-white px-3 py-2 rounded-lg border border-gray-700 text-sm w-64"
          />
        </div>
      </div>

      <div class="bg-gray-950 rounded-lg p-4 font-mono text-xs overflow-auto max-h-[600px] custom-scrollbar">
        <%= for log <- filter_logs(@log_entries, @log_filter, @log_level) do %>
          <div class="flex gap-3 py-1 hover:bg-white/5 transition-colors">
            <span class="text-gray-600 shrink-0">{format_log_timestamp(log.timestamp)}</span>
            <span class={log_level_color(log.level)}>[{String.upcase(log.level)}]</span>
            <span class="text-gray-500 shrink-0">{log.source}</span>
            <span class="text-gray-300">{log.message}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def handle_event("create_terminal_session", _params, socket) do
    machine_id =
      case socket.assigns.machines do
        [first | _] -> first.id
        _ -> "local"
      end

    case Orchestrator.Debugger.Session.start_session(machine_id, mode: :shell) do
      {:ok, session_id} ->
        send(self(), :refresh_debug_sessions)

        {:noreply,
         socket
         |> assign(:active_session_id, session_id)
         |> put_flash(:info, "Terminal session started")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start terminal: #{inspect(reason)}")}
    end
  end

  def handle_event("switch_terminal_session", %{"id" => id}, socket) do
    {:noreply, assign(socket, :active_session_id, id)}
  end

  def handle_event("close_terminal_session", %{"id" => id}, socket) do
    Orchestrator.Debugger.Session.terminate_session(id)
    send(self(), :refresh_debug_sessions)

    new_active =
      if socket.assigns.active_session_id == id do
        nil
      else
        socket.assigns.active_session_id
      end

    {:noreply, assign(socket, :active_session_id, new_active)}
  end

  def handle_event("change_terminal_theme", %{"value" => theme}, socket) do
    {:noreply,
     socket
     |> assign(:terminal_theme, theme)
     |> push_event("update_terminal_theme", %{theme: socket.assigns.terminal_themes[theme]})}
  end

  def handle_event("change_terminal_font_size", %{"value" => size}, socket) do
    size_int = String.to_integer(size)

    {:noreply,
     socket
     |> assign(:terminal_font_size, size_int)
     |> push_event("update_terminal_font_size", %{fontSize: size_int})}
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("filter_processes", %{"value" => filter}, socket) do
    {:noreply, assign(socket, process_filter: filter)}
  end

  def handle_event("sort_processes", %{"value" => sort}, socket) do
    {:noreply, assign(socket, process_sort: sort)}
  end

  def handle_event("select_process", %{"pid" => pid}, socket) do
    {:noreply, assign(socket, selected_process: pid)}
  end

  def handle_event("toggle_packet_capture", _params, socket) do
    new_running = !socket.assigns.capture_running

    socket =
      if new_running do
        assign(socket, packet_buffer_size: @packet_buffer_size)
      else
        socket
      end
      |> assign(:capture_running, new_running)

    {:noreply, socket}
  end

  def handle_event("change_capture_filter", %{"value" => filter}, socket) do
    {:noreply, assign(socket, capture_filter: filter)}
  end

  def handle_event("clear_packet_capture", _params, socket) do
    {:noreply, assign(socket, packet_capture: [])}
  end

  def handle_event("select_trace", %{"trace-id" => trace_id}, socket) do
    {:noreply, assign(socket, selected_trace: trace_id)}
  end

  def handle_event("filter_logs", %{"value" => filter}, socket) do
    {:noreply, assign(socket, log_filter: filter)}
  end

  @impl true
  def handle_event("change_log_level", %{"value" => level}, socket) do
    {:noreply, assign(socket, log_level: level)}
  end

  @impl true
  def handle_event("refresh_processes", _params, socket) do
    socket = maybe_schedule_process_refresh(socket)

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_process_state", %{"pid" => pid}, socket) do
    {:noreply, put_flash(socket, :info, "Refreshed state for #{pid}")}
  end

  @impl true
  def handle_event("send_message_to_process", %{"pid" => pid}, socket) do
    {:noreply, put_flash(socket, :info, "Message sent to #{pid}")}
  end

  @impl true
  def handle_event("suspend_process", %{"pid" => pid}, socket) do
    {:noreply, put_flash(socket, :warning, "Suspended process #{pid}")}
  end

  @impl true
  def handle_event("kill_process", %{"pid" => pid}, socket) do
    {:noreply, put_flash(socket, :error, "Killed process #{pid}")}
  end

  defp maybe_schedule_process_refresh(socket) do
    if socket.assigns.view_mode == "processes" and connected?(socket) do
      Process.send_after(
        self(),
        {:refresh_processes, socket.assigns.id},
        @process_refresh_interval
      )
    end

    socket
  end

  defp get_active_session(sessions, id) do
    Enum.find(sessions, &(&1.id == id)) || %{machine_id: "unknown"}
  end

  defp filter_and_sort_processes(processes, filter, sort_by) do
    processes
    |> filter_processes_by_query(filter)
    |> sort_processes_by(sort_by)
    |> Enum.take(100)
  end

  defp filter_processes_by_query(processes, ""), do: processes

  defp filter_processes_by_query(processes, query) do
    query_lower = String.downcase(query)

    Enum.filter(processes, fn proc ->
      String.contains?(String.downcase(proc.pid), query_lower) or
        String.contains?(String.downcase(proc.name || ""), query_lower) or
        String.contains?(String.downcase(proc.module), query_lower)
    end)
  end

  defp sort_processes_by(processes, "memory"), do: Enum.sort_by(processes, & &1.memory, :desc)

  defp sort_processes_by(processes, "reductions"),
    do: Enum.sort_by(processes, & &1.reductions, :desc)

  defp sort_processes_by(processes, "message_queue"),
    do: Enum.sort_by(processes, & &1.message_queue_len, :desc)

  defp sort_processes_by(processes, "name"), do: Enum.sort_by(processes, &(&1.name || &1.module))
  defp sort_processes_by(processes, _), do: processes

  defp get_process_details(processes, pid) do
    Enum.find(processes, &(&1.pid == pid)) ||
      %{
        pid: pid,
        name: nil,
        module: "Unknown",
        memory: 0,
        reductions: 0,
        message_queue_len: 0,
        status: "unknown",
        state: %{},
        application: nil,
        priority: "normal",
        trap_exit: false
      }
  end

  defp filter_packets(packets, "all"), do: packets

  defp filter_packets(packets, protocol) do
    Enum.filter(packets, &(String.downcase(&1.protocol) == protocol))
  end

  defp group_spans_by_trace(spans) do
    spans
    |> Enum.group_by(& &1.trace_id)
    |> Enum.map(fn {trace_id, trace_spans} ->
      sorted_spans = Enum.sort_by(trace_spans, & &1.start_time)
      first_span = List.first(sorted_spans)
      last_span = List.last(sorted_spans)

      total_duration =
        DateTime.diff(
          DateTime.add(last_span.start_time, last_span.duration, :millisecond),
          first_span.start_time,
          :millisecond
        )

      spans_with_offset =
        Enum.map(sorted_spans, fn span ->
          offset = DateTime.diff(span.start_time, first_span.start_time, :millisecond)
          Map.put(span, :start_offset, offset)
        end)

      %{
        trace_id: trace_id,
        operation: first_span.operation,
        status: if(Enum.any?(trace_spans, &(&1.status == "error")), do: "error", else: "success"),
        total_duration: total_duration,
        span_count: length(trace_spans),
        start_time: first_span.start_time,
        spans: spans_with_offset
      }
    end)
    |> Enum.sort_by(& &1.start_time, {:desc, DateTime})
  end

  defp filter_logs(logs, filter, level) do
    logs
    |> filter_by_level(level)
    |> filter_by_query(filter)
    |> Enum.take(@max_log_lines)
  end

  defp filter_by_level(logs, "all"), do: logs
  defp filter_by_level(logs, level), do: Enum.filter(logs, &(&1.level == level))

  defp filter_by_query(logs, ""), do: logs

  defp filter_by_query(logs, query) do
    query_lower = String.downcase(query)
    Enum.filter(logs, &String.contains?(String.downcase(&1.message), query_lower))
  end

  defp command_suggestions(_filter) do
    [
      %{name: "attach <machine-id>", description: "Attach terminal to machine"},
      %{name: "inspect <pid>", description: "Inspect process details"},
      %{name: "capture start", description: "Start packet capture"},
      %{name: "trace <operation>", description: "Start distributed trace"},
      %{name: "tail <source>", description: "Tail log source"}
    ]
  end

  defp format_duration(ms) when is_integer(ms) do
    cond do
      ms < 1000 -> "#{ms}ms"
      ms < 60_000 -> "#{div(ms, 1000)}s"
      ms < 3_600_000 -> "#{div(ms, 60_000)}m"
      true -> "#{div(ms, 3_600_000)}h"
    end
  end

  defp format_duration(_), do: "—"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes < 1024 -> "#{bytes}B"
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 1)}KB"
      bytes < 1024 * 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 1)}MB"
      true -> "#{Float.round(bytes / (1024 * 1024 * 1024), 2)}GB"
    end
  end

  defp format_bytes(_), do: "—"

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(_), do: "—"

  defp format_timestamp(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_log_timestamp(dt) do
    dt |> Calendar.strftime("%H:%M:%S.%f") |> String.slice(0..-4//1)
  end

  defp format_timestamp_ms(dt) do
    dt |> Calendar.strftime("%H:%M:%S.%f") |> String.slice(0..-4//1)
  end

  defp memory_color(bytes) when bytes > 100 * 1024 * 1024, do: "text-red-400"
  defp memory_color(bytes) when bytes > 10 * 1024 * 1024, do: "text-amber-400"
  defp memory_color(_), do: "text-emerald-400"

  defp message_queue_badge_class(len) when len > 100, do: "bg-red-500/20 text-red-400"
  defp message_queue_badge_class(len) when len > 10, do: "bg-amber-500/20 text-amber-400"
  defp message_queue_badge_class(_), do: "bg-gray-700/50 text-gray-400"

  defp process_status_badge("running"), do: "bg-emerald-500/20 text-emerald-400"
  defp process_status_badge("waiting"), do: "bg-blue-500/20 text-blue-400"
  defp process_status_badge("suspended"), do: "bg-amber-500/20 text-amber-400"
  defp process_status_badge(_), do: "bg-gray-700/50 text-gray-400"

  defp protocol_badge_class("gRPC"),
    do: "px-2 py-1 rounded text-xs bg-violet-500/20 text-violet-400"

  defp protocol_badge_class("HTTP/2"),
    do: "px-2 py-1 rounded text-xs bg-blue-500/20 text-blue-400"

  defp protocol_badge_class("TCP"), do: "px-2 py-1 rounded text-xs bg-cyan-500/20 text-cyan-400"

  defp protocol_badge_class("UDP"),
    do: "px-2 py-1 rounded text-xs bg-emerald-500/20 text-emerald-400"

  defp protocol_badge_class(_), do: "px-2 py-1 rounded text-xs bg-gray-700/50 text-gray-400"

  defp status_badge_class("success"), do: "bg-emerald-500/20 text-emerald-400"
  defp status_badge_class("error"), do: "bg-red-500/20 text-red-400"
  defp status_badge_class(_), do: "bg-gray-700/50 text-gray-400"

  defp log_level_color("debug"), do: "text-gray-500"
  defp log_level_color("info"), do: "text-blue-400"
  defp log_level_color("warning"), do: "text-amber-400"
  defp log_level_color("error"), do: "text-red-400"
  defp log_level_color(_), do: "text-gray-400"

  defp span_color("orchestrator"),
    do: "linear-gradient(90deg, rgba(139,92,246,0.8), rgba(124,58,237,0.8))"

  defp span_color("flyd-sim"),
    do: "linear-gradient(90deg, rgba(59,130,246,0.8), rgba(37,99,235,0.8))"

  defp span_color("net-sim"),
    do: "linear-gradient(90deg, rgba(16,185,129,0.8), rgba(5,150,105,0.8))"

  defp span_color(_), do: "linear-gradient(90deg, rgba(107,114,128,0.8), rgba(75,85,99,0.8))"
end
