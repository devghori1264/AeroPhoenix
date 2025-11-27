defmodule PhoenixUiWeb.TopologyComponent do
  use PhoenixUiWeb, :html

  attr(:regions, :list, required: true)
  attr(:machines, :list, required: true)
  attr(:active_chaos, :list, default: [])

  def render(assigns) do
    ~H"""
    <div
      id="topology-root"
      phx-hook="TopologyHook"
      data-topology={
        Jason.encode!(%{regions: @regions, machines: @machines, active_chaos: @active_chaos})
      }
      class="w-full h-full min-h-[600px] bg-slate-950/50 rounded-xl border border-white/5 relative overflow-hidden group isolate"
    >
      <svg id="topology-svg" class="w-full h-full cursor-move relative z-10">
        <defs>
          <filter id="glow-cyan" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="4" result="coloredBlur" />
            <feMerge>
              <feMergeNode in="coloredBlur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>

          <filter id="glow-violet" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="4" result="coloredBlur" />
            <feMerge>
              <feMergeNode in="coloredBlur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>

          <linearGradient id="link-gradient" gradientUnits="userSpaceOnUse">
            <stop offset="0%" stop-color="#0f172a" stop-opacity="0.1" />
            <stop offset="50%" stop-color="#06b6d4" stop-opacity="0.4" />
            <stop offset="100%" stop-color="#0f172a" stop-opacity="0.1" />
          </linearGradient>
        </defs>

        <g id="layer-links"></g>
        <g id="layer-packets"></g>
        <g id="layer-nodes"></g>
        <g id="layer-labels"></g>
      </svg>

      <div class="absolute top-6 left-6 pointer-events-none">
        <div class="space-y-2">
          <%= for region <- @regions do %>
            <div class="flex items-center gap-2 animate-fade-in-up">
              <div class="w-2 h-2 rounded-full bg-cyan-500 shadow-[0_0_10px_#06b6d4]"></div>
              <span class="text-xs font-mono text-cyan-200">
                {Map.get(region, :code) || Map.get(region, "code") || Map.get(region, :name) ||
                  Map.get(region, "name")}
              </span>
              <span class="text-[10px] text-slate-500 uppercase tracking-wider">{region.name}</span>
            </div>
          <% end %>
        </div>
      </div>

      <%= if length(@active_chaos) > 0 do %>
        <div class="absolute top-0 left-0 w-full h-1 bg-rose-500 animate-pulse"></div>
        <div class="absolute top-6 right-6 pointer-events-none">
          <div class="px-3 py-1.5 rounded bg-rose-500/10 border border-rose-500/30 backdrop-blur flex items-center gap-2 animate-pulse">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-rose-500" />
            <span class="text-xs font-bold text-rose-400 tracking-wider">
              NETWORK INSTABILITY DETECTED
            </span>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
