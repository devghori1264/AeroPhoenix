defmodule PhoenixUiWeb.ChaosPanelComponent do
  use PhoenixUiWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class={[
        "chaos-panel-container glass-panel p-6 rounded-xl border transition-all duration-500 relative overflow-hidden",
        if(length(@active_chaos) > 0,
          do: "border-rose-500/50 shadow-[0_0_30px_rgba(244,63,94,0.2)]",
          else: "border-white/5 dark:border-white/5"
        )
      ]}>
        <%= if length(@active_chaos) > 0 do %>
          <div class="absolute inset-0 bg-rose-500/5 animate-pulse"></div>
          <div class="absolute top-0 left-0 w-full h-1 bg-rose-500 animate-scanline"></div>
        <% end %>

        <div class="relative z-10">
          <div class="flex items-center justify-between mb-6">
            <div class="flex items-center gap-3">
              <div class={[
                "w-10 h-10 rounded-lg flex items-center justify-center border transition-colors",
                if(length(@active_chaos) > 0,
                  do: "bg-rose-500/20 border-rose-500/50 text-rose-400",
                  else:
                    "chaos-icon-box bg-slate-800 dark:bg-slate-800 border-slate-700 dark:border-slate-700 text-slate-500 dark:text-slate-500"
                )
              ]}>
                <.icon name="hero-fire" class="w-6 h-6" />
              </div>
              <div>
                <h3 class="chaos-title text-lg font-bold text-white dark:text-white">Chaos Engine</h3>
                <p class="text-xs text-slate-400 dark:text-slate-400 uppercase tracking-wider">
                  {if length(@active_chaos) > 0, do: "SYSTEM UNDER STRESS", else: "SYSTEM NOMINAL"}
                </p>
              </div>
            </div>

            <button
              phx-click="open-chaos-modal"
              class="px-4 py-2 rounded-lg bg-rose-500/10 border border-rose-500/50 text-rose-400 hover:bg-rose-500/20 hover:text-rose-300 transition-all font-bold text-xs uppercase tracking-wider flex items-center gap-2"
            >
              <.icon name="hero-bolt" class="w-4 h-4" /> Inject Fault
            </button>
          </div>

          <%= if length(@active_chaos) > 0 do %>
            <div class="space-y-3">
              <%= for chaos <- @active_chaos do %>
                <div class="bg-rose-950/30 border border-rose-500/30 rounded-lg p-3 flex items-center justify-between animate-fade-in-up">
                  <div class="flex items-center gap-3">
                    <span class="relative flex h-2 w-2">
                      <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-rose-400 opacity-75">
                      </span>
                      <span class="relative inline-flex rounded-full h-2 w-2 bg-rose-500"></span>
                    </span>
                    <div>
                      <div class="text-sm font-bold text-rose-200">{chaos.kind}</div>
                      <div class="text-xs text-rose-400/70 font-mono">
                        Target: {chaos.target || "ALL"}
                      </div>
                    </div>
                  </div>
                  <button
                    phx-click="stop_chaos"
                    phx-value-id={chaos.id}
                    class="text-xs text-rose-400 hover:text-white underline decoration-rose-500/50 hover:decoration-white"
                  >
                    TERMINATE
                  </button>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="chaos-empty-state h-24 flex items-center justify-center border border-dashed rounded-lg">
              <span class="text-xs font-mono chaos-empty-text">NO ACTIVE INCIDENTS</span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
