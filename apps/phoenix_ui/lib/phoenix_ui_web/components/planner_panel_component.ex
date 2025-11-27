defmodule PhoenixUiWeb.PlannerPanelComponent do
  use Phoenix.Component
  import PhoenixUiWeb.CoreComponents

  attr(:selected_machine, :map, default: nil)
  attr(:recommendations, :list, default: [])
  attr(:class, :string, default: "")

  def render(assigns) do
    ~H"""
    <div class={["card p-6 space-y-4", @class]}>
      <div class="flex items-center justify-between">
        <h3 class="text-title flex items-center gap-2">
          <.icon name="hero-sparkles" class="w-5 h-5 text-violet-500" /> Migration Planner
        </h3>
        <%= if @recommendations != [] do %>
          <span class="text-xs px-2 py-1 rounded-full bg-violet-500/10 text-violet-600 dark:text-violet-400 font-medium">
            AI-Powered
          </span>
        <% end %>
      </div>

      <%= if @selected_machine do %>
        <div class="p-3 rounded-lg bg-violet-500/5 border border-violet-500/20">
          <div class="flex items-center gap-2 mb-2">
            <.icon name="hero-cpu-chip-micro" class="w-4 h-4 text-violet-600" />
            <span class="text-sm font-semibold text-[var(--text)]">
              {@selected_machine.name || @selected_machine["name"]}
            </span>
          </div>
          <p class="text-xs text-[var(--text-muted)]">
            Current region: {@selected_machine.region || @selected_machine["region"]}
          </p>
        </div>

        <%= if @recommendations != [] do %>
          <div class="space-y-2 max-h-80 overflow-y-auto">
            <p class="text-xs font-medium text-[var(--text-secondary)] uppercase tracking-wide mb-3">
              Recommended Migrations
            </p>

            <%= for {rec, idx} <- Enum.with_index(@recommendations, 1) do %>
              <div class="p-4 rounded-lg border border-[var(--border)] bg-[var(--surface)] hover:shadow-lg transition-all cursor-pointer group">
                <div class="flex items-start justify-between mb-3">
                  <div class="flex items-center gap-2">
                    <span class="flex items-center justify-center w-6 h-6 rounded-full bg-violet-500/20 text-violet-600 text-xs font-bold">
                      {idx}
                    </span>
                    <span class="text-sm font-semibold text-[var(--text)]">
                      {get_target_region(rec)}
                    </span>
                  </div>
                  <div class="flex items-center gap-1">
                    <%= for i <- 1..5 do %>
                      <.icon
                        name="hero-star-solid"
                        class={"w-3 h-3 #{if i <= confidence_stars(rec), do: "text-amber-400", else: "text-gray-300 dark:text-gray-600"}"}
                      />
                    <% end %>
                  </div>
                </div>

                <div class="grid grid-cols-2 gap-3 mb-3">
                  <div class="space-y-1">
                    <p class="text-xs text-[var(--text-muted)]">Confidence</p>
                    <p class="text-sm font-semibold text-[var(--text)]">
                      {format_confidence(rec)}%
                    </p>
                  </div>

                  <div class="space-y-1">
                    <p class="text-xs text-[var(--text-muted)]">Est. Downtime</p>
                    <p class="text-sm font-semibold text-[var(--text)]">
                      {estimate_downtime(rec)}s
                    </p>
                  </div>

                  <div class="space-y-1">
                    <p class="text-xs text-[var(--text-muted)]">Cost Impact</p>
                    <p class={[
                      "text-sm font-semibold",
                      cost_impact_color(rec)
                    ]}>
                      {format_cost_impact(rec)}
                    </p>
                  </div>

                  <div class="space-y-1">
                    <p class="text-xs text-[var(--text-muted)]">Performance</p>
                    <p class="text-sm font-semibold text-emerald-600">
                      +{performance_gain(rec)}%
                    </p>
                  </div>
                </div>

                <div class="flex gap-2">
                  <button
                    phx-click="simulate-migration"
                    phx-value-rec-id={get_rec_id(rec)}
                    class="flex-1 btn-secondary text-xs py-1.5 group-hover:bg-violet-500/10"
                  >
                    <.icon name="hero-play" class="w-3 h-3 inline mr-1" /> Simulate
                  </button>

                  <button
                    phx-click="apply-migration"
                    phx-value-rec-id={get_rec_id(rec)}
                    class="flex-1 btn-primary text-xs py-1.5"
                  >
                    <.icon name="hero-check" class="w-3 h-3 inline mr-1" /> Apply
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        <% else %>
          <button
            phx-click="get-recommendations"
            phx-value-machine-id={@selected_machine.id || @selected_machine["id"]}
            class="w-full btn-primary flex items-center justify-center gap-2 py-3"
          >
            <.icon name="hero-sparkles" class="w-5 h-5" /> Get AI Recommendations
          </button>
        <% end %>
      <% else %>
        <div class="flex flex-col items-center justify-center py-12 text-center">
          <.icon name="hero-light-bulb" class="w-16 h-16 text-[var(--text-muted)] mb-4" />
          <p class="text-sm text-[var(--text-secondary)] mb-2">No machine selected</p>
          <p class="text-xs text-[var(--text-muted)]">
            Select a machine to see migration recommendations
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  defp get_target_region(rec) do
    rec[:target_region] || rec["target_region"] || "unknown"
  end

  defp format_confidence(rec) do
    conf = rec[:confidence] || rec["confidence"] || 0.0
    round(conf * 100)
  end

  defp confidence_stars(rec) do
    conf = format_confidence(rec)
    round(conf / 20)
  end

  defp estimate_downtime(rec) do
    rec[:downtime_estimate] || rec["downtime_estimate"] || 30
  end

  defp format_cost_impact(rec) do
    cost = rec[:cost_delta] || rec["cost_delta"] || 0

    cond do
      cost > 0 -> "+$#{abs(cost)}"
      cost < 0 -> "-$#{abs(cost)}"
      true -> "$0"
    end
  end

  defp cost_impact_color(rec) do
    cost = rec[:cost_delta] || rec["cost_delta"] || 0

    cond do
      cost > 0 -> "text-rose-600"
      cost < 0 -> "text-emerald-600"
      true -> "text-[var(--text)]"
    end
  end

  defp performance_gain(rec) do
    gain = rec[:perf_gain] || rec["perf_gain"] || 0
    round(gain * 100)
  end

  defp get_rec_id(rec) do
    rec[:id] || rec["id"] || UUID.uuid4()
  end
end
