defmodule PhoenixUiWeb.ChaosImpactComponent do
  use Phoenix.Component
  import PhoenixUiWeb.CoreComponents

  attr(:active_chaos, :list, default: [])
  attr(:class, :string, default: "")

  def render(assigns) do
    ~H"""
    <%= if @active_chaos != [] do %>
      <div class={[
        "card border-2 border-rose-500/30 shadow-2xl shadow-rose-500/20 relative overflow-hidden",
        @class
      ]}>
        <div class="absolute inset-0 bg-gradient-to-br from-rose-500/5 via-amber-500/5 to-orange-500/5 animate-pulse">
        </div>
        <div class="absolute inset-x-0 top-0 h-2 bg-gradient-to-r from-transparent via-rose-500/50 to-transparent animate-[shimmer_2s_ease-in-out_infinite]">
        </div>

        <div class="relative z-10 p-6">
          <div class="flex items-center justify-between mb-6">
            <div class="flex items-center gap-3">
              <div class="relative">
                <.icon name="hero-exclamation-triangle" class="w-8 h-8 text-rose-500 animate-pulse" />
                <span class="absolute -top-1 -right-1 w-3 h-3 bg-rose-500 rounded-full animate-ping">
                </span>
              </div>
              <div>
                <h3 class="text-lg font-bold text-rose-600 dark:text-rose-400">
                  ⚠️ CHAOS IMPACT ANALYSIS
                </h3>
                <p class="text-xs text-[var(--text-muted)]">
                  Real-time system degradation metrics
                </p>
              </div>
            </div>
            <div class="flex items-center gap-2 px-3 py-1.5 bg-rose-500/20 border border-rose-500/50 rounded-full">
              <div class="w-2 h-2 bg-rose-500 rounded-full animate-pulse"></div>
              <span class="text-xs font-bold text-rose-600 dark:text-rose-400">
                {length(@active_chaos)} ACTIVE INCIDENTS
              </span>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-4 mb-6">
            <%= for incident <- @active_chaos do %>
              <% incident_kind = incident[:kind] || incident["kind"] || "unknown" %>
              <%= case incident_kind do %>
                <% "cpu_spike" -> %>
                  <div class="p-4 rounded-xl bg-gradient-to-br from-orange-500/10 to-red-500/10 border border-orange-500/30">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-cpu-chip" class="w-5 h-5 text-orange-500 animate-pulse" />
                      <span class="text-xs font-semibold text-orange-600 dark:text-orange-400">
                        CPU OVERLOAD
                      </span>
                    </div>
                    <div class="flex items-baseline gap-2">
                      <span class="text-3xl font-bold text-orange-600 dark:text-orange-400 tabular-nums">
                        {round((incident[:severity] || incident["severity"] || 0.5) * 100)}%
                      </span>
                      <.icon name="hero-arrow-trending-up" class="w-4 h-4 text-orange-500" />
                    </div>
                    <div class="mt-2 h-2 bg-black/20 rounded-full overflow-hidden">
                      <div
                        class="h-full bg-gradient-to-r from-orange-500 to-red-500 animate-pulse"
                        style={"width: #{round((incident[:severity] || incident["severity"] || 0.5) * 100)}%"}
                      >
                      </div>
                    </div>
                    <p class="text-xs text-orange-600/80 dark:text-orange-400/80 mt-2">
                      Burning CPU cycles
                    </p>
                  </div>
                <% "memory_leak" -> %>
                  <div class="p-4 rounded-xl bg-gradient-to-br from-purple-500/10 to-pink-500/10 border border-purple-500/30">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-circle-stack" class="w-5 h-5 text-purple-500 animate-pulse" />
                      <span class="text-xs font-semibold text-purple-600 dark:text-purple-400">
                        MEMORY LEAK
                      </span>
                    </div>
                    <div class="flex items-baseline gap-2">
                      <span class="text-3xl font-bold text-purple-600 dark:text-purple-400 tabular-nums">
                        {round((incident[:severity] || incident["severity"] || 0.5) * 100)}
                      </span>
                      <span class="text-lg text-purple-500">MB/s</span>
                    </div>
                    <div class="mt-2 h-2 bg-black/20 rounded-full overflow-hidden">
                      <div
                        class="h-full bg-gradient-to-r from-purple-500 to-pink-500 animate-[grow_2s_ease-in-out_infinite]"
                        style={"width: #{round((incident[:severity] || incident["severity"] || 0.5) * 100)}%"}
                      >
                      </div>
                    </div>
                    <p class="text-xs text-purple-600/80 dark:text-purple-400/80 mt-2">
                      💾 Allocating memory
                    </p>
                  </div>
                <% "latency" -> %>
                  <div class="p-4 rounded-xl bg-gradient-to-br from-amber-500/10 to-yellow-500/10 border border-amber-500/30">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-clock" class="w-5 h-5 text-amber-500 animate-pulse" />
                      <span class="text-xs font-semibold text-amber-600 dark:text-amber-400">
                        NETWORK DELAY
                      </span>
                    </div>
                    <div class="flex items-baseline gap-2">
                      <span class="text-3xl font-bold text-amber-600 dark:text-amber-400 tabular-nums">
                        +{round((incident[:severity] || incident["severity"] || 0.5) * 1000)}
                      </span>
                      <span class="text-lg text-amber-500">ms</span>
                    </div>
                    <div class="mt-2 h-2 bg-black/20 rounded-full overflow-hidden">
                      <div
                        class="h-full bg-gradient-to-r from-amber-500 to-yellow-500 animate-pulse"
                        style={"width: #{round((incident[:severity] || incident["severity"] || 0.5) * 100)}%"}
                      >
                      </div>
                    </div>
                    <p class="text-xs text-amber-600/80 dark:text-amber-400/80 mt-2">
                      ⏱️ Requests delayed
                    </p>
                  </div>
                <% "packet_loss" -> %>
                  <div class="p-4 rounded-xl bg-gradient-to-br from-red-500/10 to-rose-500/10 border border-red-500/30">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-signal-slash" class="w-5 h-5 text-red-500 animate-pulse" />
                      <span class="text-xs font-semibold text-red-600 dark:text-red-400">
                        PACKET LOSS
                      </span>
                    </div>
                    <div class="flex items-baseline gap-2">
                      <span class="text-3xl font-bold text-red-600 dark:text-red-400 tabular-nums">
                        {round((incident[:severity] || incident["severity"] || 0.5) * 100)}%
                      </span>
                      <.icon name="hero-arrow-trending-down" class="w-4 h-4 text-red-500" />
                    </div>
                    <div class="mt-2 h-2 bg-black/20 rounded-full overflow-hidden">
                      <div
                        class="h-full bg-gradient-to-r from-red-500 to-rose-500 animate-pulse"
                        style={"width: #{round((incident[:severity] || incident["severity"] || 0.5) * 100)}%"}
                      >
                      </div>
                    </div>
                    <p class="text-xs text-red-600/80 dark:text-red-400/80 mt-2">
                      Packets dropped
                    </p>
                  </div>
                <% "disk_failure" -> %>
                  <div class="p-4 rounded-xl bg-gradient-to-br from-rose-500/10 to-red-500/10 border border-rose-500/30">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-server-stack" class="w-5 h-5 text-rose-500 animate-pulse" />
                      <span class="text-xs font-semibold text-rose-600 dark:text-rose-400">
                        DISK ERRORS
                      </span>
                    </div>
                    <div class="flex items-baseline gap-2">
                      <span class="text-3xl font-bold text-rose-600 dark:text-rose-400 tabular-nums">
                        {round((incident[:severity] || incident["severity"] || 0.5) * 100)}%
                      </span>
                      <.icon name="hero-exclamation-circle" class="w-4 h-4 text-rose-500" />
                    </div>
                    <div class="mt-2 h-2 bg-black/20 rounded-full overflow-hidden">
                      <div
                        class="h-full bg-gradient-to-r from-rose-500 to-red-500 animate-pulse"
                        style={"width: #{round((incident[:severity] || incident["severity"] || 0.5) * 100)}%"}
                      >
                      </div>
                    </div>
                    <p class="text-xs text-rose-600/80 dark:text-rose-400/80 mt-2">
                      💿 I/O operations failing
                    </p>
                  </div>
                <% "network_partition" -> %>
                  <div class="p-4 rounded-xl bg-gradient-to-br from-violet-500/10 to-purple-500/10 border border-violet-500/30">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-link-slash" class="w-5 h-5 text-violet-500 animate-pulse" />
                      <span class="text-xs font-semibold text-violet-600 dark:text-violet-400">
                        PARTITIONED
                      </span>
                    </div>
                    <div class="flex items-baseline gap-2">
                      <span class="text-3xl font-bold text-violet-600 dark:text-violet-400 tabular-nums">
                        {round((incident[:severity] || incident["severity"] || 0.5) * 100)}%
                      </span>
                      <.icon name="hero-x-mark" class="w-4 h-4 text-violet-500" />
                    </div>
                    <div class="mt-2 h-2 bg-black/20 rounded-full overflow-hidden">
                      <div
                        class="h-full bg-gradient-to-r from-violet-500 to-purple-500 animate-pulse"
                        style={"width: #{round((incident[:severity] || incident["severity"] || 0.5) * 100)}%"}
                      >
                      </div>
                    </div>
                    <p class="text-xs text-violet-600/80 dark:text-violet-400/80 mt-2">
                      🔌 Network isolated
                    </p>
                  </div>
                <% _ -> %>
                  <div class="p-4 rounded-xl bg-gradient-to-br from-gray-500/10 to-slate-500/10 border border-gray-500/30">
                    <div class="text-xs text-gray-600">Unknown chaos type</div>
                  </div>
              <% end %>
            <% end %>
          </div>

          <div class="p-4 rounded-xl bg-black/5 border border-rose-500/20">
            <div class="flex items-center justify-between">
              <div>
                <p class="text-xs text-[var(--text-muted)] mb-1">SYSTEM STATUS</p>
                <p class="text-lg font-bold text-rose-600 dark:text-rose-400">
                  ⚠️ DEGRADED PERFORMANCE
                </p>
              </div>
              <div class="text-right">
                <p class="text-xs text-[var(--text-muted)] mb-1">EXPECTED IMPACT</p>
                <div class="flex items-center gap-2">
                  <div class="flex gap-1">
                    <%= for i <- 1..5 do %>
                      <div class={[
                        "w-2 h-6 rounded-sm",
                        if(i <= length(@active_chaos),
                          do: "bg-rose-500 animate-pulse",
                          else: "bg-gray-300 dark:bg-gray-700"
                        )
                      ]}>
                      </div>
                    <% end %>
                  </div>
                  <span class="text-sm font-bold text-rose-600 dark:text-rose-400">
                    {min(length(@active_chaos), 5)}/5
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
