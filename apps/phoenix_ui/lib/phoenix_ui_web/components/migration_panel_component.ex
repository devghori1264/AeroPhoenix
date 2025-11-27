defmodule PhoenixUiWeb.MigrationPanelComponent do
  use PhoenixUiWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8" phx-hook="MigrationStudio" id="migration-studio">
      <%= if length(@active_migrations) > 0 do %>
        <div class="grid grid-cols-1 gap-6">
          <%= for migration <- @active_migrations do %>
            <div
              class="glass-panel p-6 rounded-xl border border-cyan-500/30 shadow-[0_0_30px_rgba(6,182,212,0.1)] relative overflow-hidden group"
              data-migration-id={migration.id}
              data-migration-progress={migration.progress}
              data-migration-status={migration.status}
            >
              <div class="absolute inset-0 opacity-10 pointer-events-none">
                <div class="absolute inset-0 bg-[linear-gradient(90deg,transparent,rgba(6,182,212,0.2),transparent)] animate-flow-right">
                </div>
              </div>

              <div class="flex items-center justify-between mb-8 relative z-10">
                <div class="flex items-center gap-4">
                  <div class="w-12 h-12 rounded-lg bg-cyan-500/10 border border-cyan-500/20 flex items-center justify-center animate-pulse">
                    <.icon name="hero-rocket-launch" class="w-6 h-6 text-cyan-400" />
                  </div>
                  <div>
                    <h3 class="text-lg font-bold text-white flex items-center gap-2">
                      Migration #{String.slice(migration.id, 0..7)}
                      <span class="px-2 py-0.5 rounded text-[10px] bg-cyan-500/20 text-cyan-300 border border-cyan-500/30 uppercase tracking-wider">
                        {migration.status}
                      </span>
                    </h3>
                    <div class="flex items-center gap-2 text-sm text-slate-400 font-mono">
                      <span>{migration.source_machine}</span>
                      <.icon name="hero-arrow-right" class="w-4 h-4 text-cyan-500" />
                      <span>{migration.target_machine}</span>
                    </div>
                  </div>
                </div>

                <div class="text-right">
                  <div class="text-3xl font-bold text-cyan-400 font-mono">
                    {migration.progress}%
                  </div>
                  <div class="text-xs text-slate-500 uppercase tracking-wider">Completion</div>
                </div>
              </div>

              <div class="migration-cinematic-progress relative z-10"></div>

              <div class="grid grid-cols-3 gap-4 mb-8 relative z-10">
                <div class="bg-slate-900/50 rounded-lg p-3 border border-white/5">
                  <div class="text-[10px] text-slate-500 uppercase tracking-wider mb-1">
                    Data Gravity (Disk)
                  </div>
                  <div class="flex items-end gap-2">
                    <span class="text-lg font-bold text-white font-mono">
                      {format_bytes(migration.metrics.memory_size)}
                    </span>
                    <div class="flex-1 h-1.5 bg-slate-800 rounded-full mb-1.5">
                      <div class="h-full bg-violet-500 rounded-full" style="width: 80%"></div>
                    </div>
                  </div>
                </div>

                <div class="bg-slate-900/50 rounded-lg p-3 border border-white/5">
                  <div class="text-[10px] text-slate-500 uppercase tracking-wider mb-1">
                    Network Friction
                  </div>
                  <div class="flex items-end gap-2">
                    <span class="text-lg font-bold text-emerald-400 font-mono">
                      {migration.metrics.transfer_rate} MB/s
                    </span>
                    <.icon name="hero-bolt" class="w-4 h-4 text-emerald-500 mb-1" />
                  </div>
                </div>

                <div class="bg-slate-900/50 rounded-lg p-3 border border-white/5">
                  <div class="text-[10px] text-slate-500 uppercase tracking-wider mb-1">
                    Dirty Pages
                  </div>
                  <div class="flex items-end gap-2">
                    <span class="text-lg font-bold text-rose-400 font-mono">
                      {migration.metrics.checkpoint_count}
                    </span>
                    <span class="text-xs text-slate-500 mb-1.5">pages/sec</span>
                  </div>
                </div>
              </div>

              <div class="migration-bandwidth-graph relative z-10"></div>

              <div class="migration-checkpoint-timeline relative z-10"></div>

              <div class="migration-countdown relative z-10"></div>
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="glass-panel p-12 rounded-xl border border-dashed border-slate-700 flex flex-col items-center justify-center text-center">
          <div class="w-16 h-16 rounded-full bg-slate-800/50 flex items-center justify-center mb-4">
            <.icon name="hero-rocket-launch" class="w-8 h-8 text-slate-600" />
          </div>
          <h3 class="text-lg font-bold text-slate-400">No Active Migrations</h3>
          <p class="text-slate-500 max-w-sm mt-2">
            The system is currently stable. Initiate a migration from the Overview tab to see the physics engine in action.
          </p>
        </div>
      <% end %>

      <div class="space-y-4">
        <h4 class="text-sm font-bold text-slate-400 uppercase tracking-wider">Recent Completions</h4>
        <div class="space-y-2">
          <%= for migration <- Enum.take(@completed_migrations, 5) do %>
            <div class="glass-panel p-3 rounded-lg flex items-center justify-between hover:bg-white/5 transition-colors">
              <div class="flex items-center gap-3">
                <div class="w-2 h-2 rounded-full bg-emerald-500"></div>
                <span class="font-mono text-sm text-slate-300">{migration.id}</span>
              </div>
              <div class="flex items-center gap-6 text-xs text-slate-500">
                <span>{format_duration(migration.duration)}</span>
                <span>{format_bytes(migration.total_bytes)}</span>
                <span class="text-emerald-400">COMPLETED</span>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp format_bytes(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_duration(ms), do: "#{div(ms, 1000)}s"
end
