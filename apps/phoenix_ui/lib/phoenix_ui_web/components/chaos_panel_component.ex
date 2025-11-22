defmodule PhoenixUiWeb.ChaosPanelComponent do
  use Phoenix.Component
  import PhoenixUiWeb.CoreComponents

  attr :active_chaos, :list, default: []
  attr :chaos_logs, :list, default: []
  attr :class, :string, default: ""

  def render(assigns) do
    ~H"""
    <div class={["card p-5 sm:p-6 space-y-4", @class]}>
      <div class="flex items-center justify-between">
        <h3 class="text-title flex items-center gap-2">
          <.icon
            name="hero-bolt"
            class={
              if(@active_chaos != [],
                do: "w-5 h-5 text-amber-500 animate-pulse",
                else: "w-5 h-5 text-amber-500"
              )
            }
          />
          <span class="gradient-text">Chaos Engineering</span>
        </h3>
        <span class={[
          "text-xs px-3 py-1.5 rounded-full glass border font-semibold",
          if(@active_chaos != [],
            do:
              "border-amber-500/50 bg-gradient-to-r from-amber-500/20 to-orange-500/20 text-amber-600 dark:text-amber-400 animate-pulse",
            else:
              "border-amber-500/20 bg-gradient-to-r from-amber-500/10 to-orange-500/10 text-amber-600 dark:text-amber-400"
          )
        ]}>
          {length(@active_chaos)} Active
        </span>
      </div>

      <%= if @active_chaos != [] do %>
        <div class="space-y-2 max-h-64 overflow-y-auto pr-1">
          <%= for incident <- @active_chaos do %>
            <div class="p-3 rounded-xl glass border border-amber-500/30 hover:border-amber-500/60 shadow-lg transition-all duration-300 group relative overflow-hidden">
              <div class="absolute inset-0 bg-gradient-to-r from-amber-500/5 to-orange-500/5 animate-pulse">
              </div>

              <div class="relative z-10">
                <div class="flex items-start justify-between mb-2">
                  <div class="flex items-center gap-2">
                    <span class={[
                      "w-2 h-2 rounded-full animate-pulse shadow-lg",
                      chaos_dot_class(incident)
                    ]}>
                    </span>
                    <span class="text-sm font-semibold text-[var(--text)]">
                      {chaos_kind_label(incident)}
                    </span>
                    <span class="text-xs px-2 py-0.5 rounded-full bg-amber-500/20 text-amber-600 dark:text-amber-400 font-mono animate-pulse">
                      LIVE
                    </span>
                  </div>
                  <span class="text-xs text-[var(--text-muted)] font-mono">
                    {format_incident_id(incident)}
                  </span>
                </div>

                <div class="mb-2 text-xs text-[var(--text-secondary)] italic">
                  {chaos_effect_description(incident)}
                </div>

                <div class="space-y-1.5 text-xs">
                  <div class="flex justify-between items-center">
                    <span class="text-[var(--text-muted)]">Target:</span>
                    <span class="text-[var(--text-secondary)] font-mono bg-[var(--surface-hover)] px-2 py-0.5 rounded">
                      {get_target(incident)}
                    </span>
                  </div>

                  <div class="flex justify-between items-center">
                    <span class="text-[var(--text-muted)]">Severity:</span>
                    <div class="flex items-center gap-1">
                      <%= for i <- 1..5 do %>
                        <div class={[
                          "w-1.5 h-3 rounded-sm transition-all duration-300",
                          if(i <= severity_level(incident),
                            do:
                              "bg-gradient-to-t from-amber-600 to-amber-400 shadow-sm shadow-amber-500/50",
                            else: "bg-[var(--border)]"
                          )
                        ]}>
                        </div>
                      <% end %>
                      <span class="ml-1 font-mono text-amber-600 dark:text-amber-400">
                        {round((incident[:severity] || incident["severity"] || 0.5) * 100)}%
                      </span>
                    </div>
                  </div>

                  <div class="flex justify-between items-center pt-1 border-t border-[var(--border)]">
                    <span class="text-[var(--text-muted)]">Running:</span>
                    <span class="text-[var(--text-secondary)] font-mono tabular-nums">
                      {format_duration(incident)}
                    </span>
                  </div>
                </div>

                <button
                  phx-click="stop-chaos"
                  phx-value-id={get_incident_id(incident)}
                  class="mt-3 w-full btn-secondary text-xs py-2 hover:bg-rose-500/10 hover:border-rose-500 hover:text-rose-600 group-hover:scale-[1.02] transition-all"
                >
                  <.icon name="hero-stop" class="w-3 h-3 inline mr-1" /> Stop & Heal Incident
                </button>
              </div>
            </div>
          <% end %>
        </div>

        <div class="mt-3 p-3 rounded-xl glass border border-amber-500/20 bg-gradient-to-br from-amber-500/5 to-orange-500/5 max-h-60 overflow-y-auto">
          <div class="flex items-center gap-2 mb-3">
            <div class="w-2 h-2 rounded-full bg-amber-500 animate-pulse"></div>
            <span class="text-xs font-semibold text-amber-600 dark:text-amber-400">
              📊 Live Activity Feed
            </span>
          </div>
          <div class="space-y-2">
            <%= if @chaos_logs != [] do %>
              <%= for log <- Enum.take(@chaos_logs, 8) do %>
                <div class="activity-event-slide-in glass border border-[var(--border)] rounded-lg p-2 transition-all duration-300 hover:shadow-lg hover:scale-[1.01]">
                  <div class="flex items-start gap-2">
                    <div class="flex-shrink-0 w-6 h-6 rounded-md flex items-center justify-center text-sm bg-gradient-to-br from-amber-500/20 to-orange-500/20">
                      {log_emoji(log)}
                    </div>
                    <div class="flex-1 min-w-0">
                      <div class="text-xs text-[var(--text)] font-medium">
                        {log[:message] || log["message"] || "Activity log"}
                      </div>
                      <div class="text-xs text-[var(--text-muted)] mt-0.5 font-mono">
                        {format_log_time(log)}
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% else %>
              <%= for incident <- Enum.take(@active_chaos, 3) do %>
                <div class="flex items-center gap-2 text-xs text-[var(--text-muted)] font-mono animate-pulse">
                  <span class="text-amber-500">→</span>
                  <span>{chaos_activity_message(incident)}</span>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% else %>
        <div class="flex flex-col items-center justify-center py-8 sm:py-10 text-center">
          <.icon
            name="hero-shield-check"
            class="w-12 h-12 sm:w-14 sm:h-14 text-emerald-500 mb-3 animate-pulse"
          />
          <p class="text-sm font-medium text-[var(--text-secondary)]">No active chaos incidents</p>
          <p class="text-xs text-[var(--text-muted)] mt-1">System running smoothly ✅</p>
        </div>
      <% end %>

      <div class="pt-4 border-t border-[var(--border)]">
        <button
          phx-click="open-chaos-modal"
          class="w-full btn-demo flex items-center justify-center gap-2 group"
        >
          <.icon name="hero-beaker" class="w-4 h-4 group-hover:scale-110 transition-transform" />
          Start New Chaos Test
        </button>
      </div>
    </div>
    """
  end

  defp chaos_kind_label(incident) do
    kind = incident[:kind] || incident["kind"] || "unknown"

    case to_string(kind) do
      "latency" -> "Network Latency"
      "packet_loss" -> "Packet Loss"
      "cpu_spike" -> "CPU Spike"
      "memory_leak" -> "Memory Leak"
      "disk_failure" -> "Disk Failure"
      "network_partition" -> "Network Partition"
      _ -> String.capitalize(to_string(kind))
    end
  end

  defp chaos_dot_class(incident) do
    kind = incident[:kind] || incident["kind"] || "unknown"

    case to_string(kind) do
      "latency" -> "bg-amber-500"
      "packet_loss" -> "bg-rose-500"
      "cpu_spike" -> "bg-orange-500"
      "memory_leak" -> "bg-red-500"
      "disk_failure" -> "bg-rose-600"
      "network_partition" -> "bg-purple-500"
      _ -> "bg-gray-500"
    end
  end

  defp get_target(incident) do
    target = incident[:target] || incident["target"] || "unknown"
    String.slice(to_string(target), 0, 24)
  end

  defp severity_level(incident) do
    severity = incident[:severity] || incident["severity"] || 0.5
    round(severity * 5)
  end

  defp format_incident_id(incident) do
    id = incident[:id] || incident["id"] || ""
    String.slice(to_string(id), 0, 8)
  end

  defp get_incident_id(incident) do
    incident[:id] || incident["id"] || ""
  end

  defp chaos_effect_description(incident) do
    kind = incident[:kind] || incident["kind"] || "unknown"
    severity = incident[:severity] || incident["severity"] || 0.5

    case to_string(kind) do
      "latency" -> "⏱️ Adding #{round(severity * 1000)} ms network delay"
      "packet_loss" -> "📦 Dropping #{round(severity * 100)}% of packets"
      "cpu_spike" -> "Consuming #{round(severity * 100)}% CPU load"
      "memory_leak" -> "💾 Leaking #{round(severity * 100)} MB of memory"
      "disk_failure" -> "💿 Causing #{round(severity * 100)}% I/O errors"
      "network_partition" -> "🔌 Blocking #{round(severity * 100)}% of connections"
      _ -> "Unknown chaos effect"
    end
  end

  defp format_duration(incident) do
    started_at = incident[:started_at] || incident["started_at"]

    case started_at do
      nil ->
        "unknown"

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, start_time, _} ->
            now = DateTime.utc_now()
            diff_seconds = DateTime.diff(now, start_time)

            cond do
              diff_seconds < 60 -> "#{diff_seconds}s"
              diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m #{rem(diff_seconds, 60)}s"
              true -> "#{div(diff_seconds, 3600)}h #{div(rem(diff_seconds, 3600), 60)}m"
            end

          _ ->
            "unknown"
        end

      %DateTime{} = start_time ->
        now = DateTime.utc_now()
        diff_seconds = DateTime.diff(now, start_time)

        cond do
          diff_seconds < 60 -> "#{diff_seconds}s"
          diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m #{rem(diff_seconds, 60)}s"
          true -> "#{div(diff_seconds, 3600)}h #{div(rem(diff_seconds, 3600), 60)}m"
        end

      _ ->
        "unknown"
    end
  end

  defp chaos_activity_message(incident) do
    kind = incident[:kind] || incident["kind"] || "unknown"
    target = get_target(incident)

    case to_string(kind) do
      "latency" -> "Network delayed on #{target}"
      "packet_loss" -> "Packets dropping on #{target}"
      "cpu_spike" -> "CPU burning on #{target}"
      "memory_leak" -> "Memory leaking on #{target}"
      "disk_failure" -> "Disk errors on #{target}"
      "network_partition" -> "Network partitioned from #{target}"
      _ -> "Active chaos on #{target}"
    end
  end

  defp log_emoji(log) do
    message = log[:message] || log["message"] || ""

    cond do
      String.contains?(message, "cpu") or String.contains?(message, "CPU") -> "🔥"
      String.contains?(message, "memory") or String.contains?(message, "Memory") -> "💾"
      String.contains?(message, "latency") or String.contains?(message, "Latency") -> "⏱️"
      String.contains?(message, "packet") -> "📉"
      String.contains?(message, "disk") or String.contains?(message, "Disk") -> "💽"
      String.contains?(message, "partition") or String.contains?(message, "network") -> "🔌"
      String.contains?(message, "Stop") -> "✅"
      true -> "⚡"
    end
  end

  defp format_log_time(log) do
    timestamp = log[:timestamp] || log["timestamp"]

    case timestamp do
      nil ->
        "now"

      ts when is_binary(ts) ->
        case String.split(ts, "T") do
          [_, time_part] ->
            time_part
            |> String.split(".")
            |> List.first()
            |> then(fn t -> String.slice(t || "", 0, 8) end)

          _ ->
            "now"
        end

      _ ->
        "now"
    end
  end
end
