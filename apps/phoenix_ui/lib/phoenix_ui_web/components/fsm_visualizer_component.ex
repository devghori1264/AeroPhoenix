defmodule PhoenixUiWeb.FsmVisualizerComponent do
  use PhoenixUiWeb, :live_component
  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:selected_machine, nil)
     |> assign(:selected_state, nil)
     |> assign(:transition_filter, "all")
     |> assign(:view_mode, "graph")
     |> assign(:show_metadata, false)
     |> assign(:animation_speed, 1.0)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:fsm_states, fn -> [] end)
      |> assign_new(:machines, fn -> [] end)
      |> assign_new(:transition_history, fn -> [] end)
      |> assign_new(:state_analytics, fn -> %{} end)
      |> compute_graph_layout()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-4">
          <div class="w-12 h-12 rounded-xl bg-violet-500/10 border border-violet-500/20 flex items-center justify-center relative overflow-hidden group">
            <div class="absolute inset-0 bg-violet-500/20 blur-xl group-hover:bg-violet-500/30 transition-all">
            </div>
            <.icon name="hero-cpu-chip" class="w-6 h-6 text-violet-400 relative z-10" />
          </div>
          <div>
            <h3 class="text-xl font-bold text-white hologram-text">FSM Hologram</h3>
            <p class="text-sm text-slate-400 font-mono">
              <span class="text-violet-400">{length(@machines)}</span>
              NODES · <span class="text-cyan-400">{total_states(@fsm_states)}</span>
              STATES
            </p>
          </div>
        </div>

        <div class="flex items-center gap-3">
          <div class="flex items-center gap-1 p-1 rounded-lg bg-slate-900/50 border border-white/10">
            <button
              phx-click="set_view_mode"
              phx-value-mode="graph"
              phx-target={@myself}
              class={[
                "px-3 py-1.5 rounded-md text-xs font-medium transition-all duration-200 uppercase tracking-wider",
                if(@view_mode == "graph",
                  do:
                    "bg-violet-500/20 text-violet-300 border border-violet-500/30 shadow-[0_0_10px_rgba(139,92,246,0.2)]",
                  else: "text-slate-500 hover:text-slate-300"
                )
              ]}
            >
              Graph
            </button>
            <button
              phx-click="set_view_mode"
              phx-value-mode="timeline"
              phx-target={@myself}
              class={[
                "px-3 py-1.5 rounded-md text-xs font-medium transition-all duration-200 uppercase tracking-wider",
                if(@view_mode == "timeline",
                  do:
                    "bg-violet-500/20 text-violet-300 border border-violet-500/30 shadow-[0_0_10px_rgba(139,92,246,0.2)]",
                  else: "text-slate-500 hover:text-slate-300"
                )
              ]}
            >
              Timeline
            </button>
            <button
              phx-click="set_view_mode"
              phx-value-mode="analytics"
              phx-target={@myself}
              class={[
                "px-3 py-1.5 rounded-md text-xs font-medium transition-all duration-200 uppercase tracking-wider",
                if(@view_mode == "analytics",
                  do:
                    "bg-violet-500/20 text-violet-300 border border-violet-500/30 shadow-[0_0_10px_rgba(139,92,246,0.2)]",
                  else: "text-slate-500 hover:text-slate-300"
                )
              ]}
            >
              Analytics
            </button>
          </div>

          <button
            phx-click="refresh_fsm"
            phx-target={@myself}
            class="p-2 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 hover:text-white transition-colors border border-white/5"
          >
            <.icon name="hero-arrow-path" class="w-5 h-5" />
          </button>
        </div>
      </div>

      <div class="flex gap-1 h-1.5 w-full rounded-full overflow-hidden bg-slate-900">
        <%= for {state_name, count} <- state_distribution(@fsm_states) do %>
          <div
            class={"h-full #{state_bg_class(state_name)}"}
            style={"width: #{count / max(total_states(@fsm_states), 1) * 100}%"}
            title={"#{state_name}: #{count}"}
          >
          </div>
        <% end %>
      </div>

      <div class="glass-panel rounded-xl p-1 min-h-[600px] relative">
        <%= case @view_mode do %>
          <% "graph" -> %>
            {render_graph_view(assigns)}
          <% "timeline" -> %>
            {render_timeline_view(assigns)}
          <% "analytics" -> %>
            {render_analytics_view(assigns)}
        <% end %>
      </div>
    </div>
    """
  end

  defp render_graph_view(assigns) do
    ~H"""
    <div class="relative w-full h-[600px] bg-slate-950/50 rounded-lg overflow-hidden group">
      <div class="absolute inset-0 bg-[radial-gradient(circle_at_center,rgba(139,92,246,0.05),transparent_70%)]">
      </div>

      <svg
        id="fsm-graph"
        class="w-full h-full"
        viewBox="0 0 1200 600"
        phx-hook="FsmGraphHook"
      >
        <defs>
          <filter id="glow-node">
            <feGaussianBlur stdDeviation="2.5" result="coloredBlur" />
            <feMerge>
              <feMergeNode in="coloredBlur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>

          <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
            <polygon points="0 0, 10 3.5, 0 7" fill="#475569" />
          </marker>

          <marker
            id="arrowhead-active"
            markerWidth="10"
            markerHeight="7"
            refX="9"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 10 3.5, 0 7" fill="#8b5cf6" />
          </marker>
        </defs>

        <g class="edges">
          <%= for edge <- @graph_layout.edges do %>
            <path
              d={edge.path}
              fill="none"
              stroke={if edge.active, do: "#8b5cf6", else: "#334155"}
              stroke-width={if edge.active, do: "2", else: "1"}
              stroke-dasharray={if edge.active, do: "none", else: "4 4"}
              marker-end={if edge.active, do: "url(#arrowhead-active)", else: "url(#arrowhead)"}
              class="transition-all duration-500"
              opacity={if edge.active, do: "1", else: "0.3"}
            />
          <% end %>
        </g>

        <g class="nodes">
          <%= for node <- @graph_layout.nodes do %>
            <g transform={"translate(#{node.x}, #{node.y})"} class="cursor-pointer group/node">
              <%= if node.active do %>
                <circle r="40" fill="none" stroke="#8b5cf6" stroke-width="1" opacity="0.5">
                  <animate attributeName="r" from="30" to="50" dur="2s" repeatCount="indefinite" />
                  <animate
                    attributeName="opacity"
                    from="0.5"
                    to="0"
                    dur="2s"
                    repeatCount="indefinite"
                  />
                </circle>
              <% end %>

              <circle
                r="30"
                fill="#0f172a"
                stroke={node.stroke_color}
                stroke-width="2"
                filter="url(#glow-node)"
                class="transition-all duration-300 group-hover/node:stroke-white"
              />

              <text y="5" text-anchor="middle" class="text-xl pointer-events-none fill-slate-200">
                {state_icon(node.state)}
              </text>

              <text
                y="45"
                text-anchor="middle"
                class="text-xs font-bold fill-slate-400 uppercase tracking-wider"
              >
                {node.state}
              </text>

              <g transform="translate(20, -20)">
                <circle r="10" fill="#1e293b" stroke="#334155" />
                <text y="3" text-anchor="middle" class="text-[10px] font-bold fill-white">
                  {node.count}
                </text>
              </g>
            </g>
          <% end %>
        </g>
      </svg>
    </div>
    """
  end

  defp render_timeline_view(assigns) do
    ~H"""
    <div class="p-6 h-[600px] overflow-y-auto custom-scrollbar">
      <div class="relative border-l border-slate-800 ml-4 space-y-8">
        <%= for transition <- Enum.take(@transition_history, 20) do %>
          <div class="relative pl-8 group">
            <div class={[
              "absolute left-[-5px] top-0 w-2.5 h-2.5 rounded-full border-2 border-slate-950 transition-all duration-300",
              if(transition.success,
                do: "bg-emerald-500 group-hover:shadow-[0_0_10px_#10b981]",
                else: "bg-rose-500 group-hover:shadow-[0_0_10px_#f43f5e]"
              )
            ]}>
            </div>

            <div class="glass-panel p-4 rounded-lg border-l-2 border-transparent hover:border-violet-500 transition-all">
              <div class="flex items-center justify-between mb-2">
                <div class="flex items-center gap-3">
                  <span class="font-mono text-xs text-violet-400">{transition.machine_id}</span>
                  <span class="text-slate-600 text-xs">•</span>
                  <span class="text-xs text-slate-400">
                    {format_relative_time(transition.timestamp)}
                  </span>
                </div>
                <div class={[
                  "text-[10px] font-bold px-2 py-0.5 rounded uppercase tracking-wider",
                  if(transition.success,
                    do: "bg-emerald-500/10 text-emerald-400",
                    else: "bg-rose-500/10 text-rose-400"
                  )
                ]}>
                  {if transition.success, do: "SUCCESS", else: "FAILED"}
                </div>
              </div>

              <div class="flex items-center gap-3 text-sm">
                <span class="font-bold text-slate-400">{transition.from_state}</span>
                <.icon name="hero-arrow-right" class="w-4 h-4 text-slate-600" />
                <span class="font-bold text-white">{transition.to_state}</span>
              </div>

              <div class="mt-2 text-xs font-mono text-slate-500">
                Duration: <span class="text-slate-300">{transition.duration}ms</span>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_analytics_view(assigns) do
    ~H"""
    <div class="p-6 h-[600px] overflow-y-auto custom-scrollbar">
      <div class="grid grid-cols-2 gap-6">
        <%= for {state, stats} <- @state_analytics do %>
          <div class="glass-panel p-5 rounded-xl relative overflow-hidden group">
            <div class="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
              <.icon name="hero-chart-pie" class="w-16 h-16" />
            </div>

            <h4 class="text-sm font-bold text-slate-400 uppercase tracking-wider mb-4">{state}</h4>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <div class="text-xs text-slate-500 mb-1">Avg Duration</div>
                <div class="text-xl font-mono font-bold text-white">
                  {format_duration(stats.avg_duration)}
                </div>
              </div>
              <div>
                <div class="text-xs text-slate-500 mb-1">Total Time</div>
                <div class="text-xl font-mono font-bold text-violet-400">
                  {format_duration(stats.total_duration)}
                </div>
              </div>
            </div>

            <div class="mt-4 pt-4 border-t border-white/5">
              <div class="flex justify-between items-center">
                <span class="text-xs text-slate-500">Frequency</span>
                <span class="text-xs font-bold text-cyan-400">{stats.count} events</span>
              </div>
              <div class="mt-2 h-1 bg-slate-800 rounded-full overflow-hidden">
                <div class="h-full bg-cyan-500" style={"width: #{min(stats.count * 5, 100)}%"}></div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp state_icon("created"), do: "✨"
  defp state_icon("running"), do: "⚡"
  defp state_icon("migrating"), do: "🚀"
  defp state_icon("stopped"), do: "🛑"
  defp state_icon("error"), do: "🔥"
  defp state_icon(_), do: "❓"

  defp state_bg_class("created"), do: "bg-violet-500"
  defp state_bg_class("running"), do: "bg-emerald-500"
  defp state_bg_class("migrating"), do: "bg-cyan-500"
  defp state_bg_class("stopped"), do: "bg-slate-500"
  defp state_bg_class("error"), do: "bg-rose-500"
  defp state_bg_class(_), do: "bg-slate-700"

  defp total_states(states), do: length(states)

  defp state_distribution(states) do
    states
    |> Enum.group_by(& &1.current_state)
    |> Enum.map(fn {k, v} -> {k, length(v)} end)
    |> Enum.sort_by(fn {_k, v} -> v end, :desc)
  end

  defp compute_graph_layout(socket) do
    states = ["created", "running", "migrating", "stopped", "error"]
    total = length(states)

    nodes =
      Enum.with_index(states)
      |> Enum.map(fn {state, i} ->
        angle = i / total * 2 * :math.pi()

        %{
          state: state,
          x: 600 + :math.cos(angle) * 200,
          y: 300 + :math.sin(angle) * 200,
          active: socket.assigns.selected_state == state,
          stroke_color: state_color(state),
          count: Enum.count(socket.assigns.fsm_states, &(&1.current_state == state))
        }
      end)

    edges =
      [
        %{from: "created", to: "running"},
        %{from: "running", to: "migrating"},
        %{from: "migrating", to: "running"},
        %{from: "running", to: "stopped"},
        %{from: "stopped", to: "running"},
        %{from: "running", to: "error"}
      ]
      |> Enum.map(fn edge ->
        from_node = Enum.find(nodes, &(&1.state == edge.from))
        to_node = Enum.find(nodes, &(&1.state == edge.to))

        %{
          path: "M#{from_node.x},#{from_node.y} L#{to_node.x},#{to_node.y}",
          active: false
        }
      end)

    assign(socket, graph_layout: %{nodes: nodes, edges: edges})
  end

  defp state_color("created"), do: "#8b5cf6"
  defp state_color("running"), do: "#10b981"
  defp state_color("migrating"), do: "#06b6d4"
  defp state_color("stopped"), do: "#64748b"
  defp state_color("error"), do: "#f43f5e"
  defp state_color(_), do: "#94a3b8"

  defp format_duration(ms) when is_number(ms), do: "#{ms}ms"
  defp format_duration(_), do: "0ms"

  defp format_relative_time(nil), do: "never"

  defp format_relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end
end
