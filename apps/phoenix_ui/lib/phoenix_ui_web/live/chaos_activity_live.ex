defmodule PhoenixUiWeb.ChaosActivityLive do
  use PhoenixUiWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:activity_events, [])
     |> assign(:max_events, 15)}
  end

  @impl true
  def update(assigns, socket) do
    events = build_activity_events(assigns.active_chaos, assigns.chaos_logs)

    {:ok,
     socket
     |> assign(:active_chaos, assigns[:active_chaos] || [])
     |> assign(:chaos_logs, assigns[:chaos_logs] || [])
     |> assign(:activity_events, Enum.take(events, socket.assigns.max_events))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card card-hover-lift fade-in p-4 sm:p-6 overflow-hidden">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-lg font-bold text-[var(--text)] flex items-center gap-2">
          <span class="text-2xl animate-pulse">📊</span>
          <span>Live Chaos Activity</span>
        </h3>
        <div class="flex items-center gap-2 text-xs text-[var(--text-muted)] bg-[var(--surface-hover)] px-3 py-1.5 rounded-full">
          <span class="w-1.5 h-1.5 bg-rose-500 rounded-full animate-ping"></span>
          <span class="font-semibold text-rose-500">{length(@activity_events)}</span>
          <span>events</span>
        </div>
      </div>

      <div
        id="activity-stream"
        class="relative h-[400px] overflow-hidden"
      >
        <%= if length(@activity_events) == 0 do %>
          <div class="flex flex-col items-center justify-center h-full text-[var(--text-muted)]">
            <div class="text-6xl mb-4 opacity-30">💤</div>
            <p class="text-sm">No chaos activity detected</p>
            <p class="text-xs mt-1 opacity-70">Start a chaos scenario to see live events</p>
          </div>
        <% else %>
          <div class="space-y-2 activity-container">
            <%= for {event, index} <- Enum.with_index(@activity_events) do %>
              <div
                class="activity-event-slide-in glass border border-[var(--border)] rounded-lg p-3 transition-all duration-300 hover:shadow-lg hover:scale-[1.01]"
                style={"animation-delay: #{index * 0.05}s;"}
              >
                <div class="flex items-start gap-3">
                  <div class={[
                    "flex-shrink-0 w-10 h-10 rounded-lg flex items-center justify-center text-xl transition-all duration-300",
                    chaos_bg_class(event.severity)
                  ]}>
                    {chaos_emoji(event.kind)}
                  </div>

                  <div class="flex-1 min-w-0">
                    <div class="flex items-center justify-between gap-2 mb-1">
                      <h4 class="font-semibold text-sm text-[var(--text)] truncate">
                        {event.title}
                      </h4>
                      <span class="flex-shrink-0 text-xs text-[var(--text-muted)] opacity-70">
                        {event.timestamp}
                      </span>
                    </div>

                    <p class="text-xs text-[var(--text-secondary)] mb-2">
                      {event.message}
                    </p>

                    <div class="flex items-center gap-2">
                      <div class="flex-1 h-1.5 bg-[var(--surface-hover)] rounded-full overflow-hidden">
                        <div
                          class={[
                            "h-full transition-all duration-1000 ease-out",
                            chaos_progress_class(event.severity)
                          ]}
                          style={"width: #{event.severity}%; animation: progressGrow 1s ease-out;"}
                        >
                        </div>
                      </div>
                      <span class={[
                        "text-xs font-bold px-2 py-0.5 rounded-full",
                        severity_badge_class(event.severity)
                      ]}>
                        {round(event.severity)}%
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp build_activity_events(active_chaos, chaos_logs) do
    active_events =
      active_chaos
      |> Enum.map(fn chaos ->
        %{
          id: chaos.id,
          kind: chaos.kind,
          title: format_chaos_title(chaos.kind),
          message: format_chaos_message(chaos),
          severity: chaos.severity * 100,
          timestamp: format_timestamp(chaos.inserted_at),
          type: :active
        }
      end)

    log_events =
      chaos_logs
      |> Enum.take(10)
      |> Enum.map(fn log ->
        kind = extract_kind_from_message(log[:message] || log["message"] || "")
        message = log[:message] || log["message"] || ""
        timestamp = log[:timestamp] || log["timestamp"] || "now"

        %{
          id: "log-#{:erlang.phash2(log)}",
          kind: kind,
          title: message,
          message: message,
          severity: extract_severity_from_log(log),
          timestamp: timestamp,
          type: :log
        }
      end)

    (active_events ++ log_events)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.timestamp, :desc)
  end

  defp format_chaos_title("cpu_spike"), do: "🔥 CPU Spike Detected"
  defp format_chaos_title("memory_leak"), do: "💾 Memory Leak Active"
  defp format_chaos_title("latency"), do: "⏱️ Network Latency Injected"
  defp format_chaos_title("packet_loss"), do: "📉 Packet Loss Occurring"
  defp format_chaos_title("disk_failure"), do: "💽 Disk I/O Failure"
  defp format_chaos_title("network_partition"), do: "🔌 Network Partition"
  defp format_chaos_title(_), do: "⚠️ Chaos Event"

  defp format_chaos_message(chaos) do
    severity_pct = round(chaos.severity * 100)

    case chaos.kind do
      "cpu_spike" ->
        "CPU load increased to #{severity_pct}% - #{cpu_thread_count(severity_pct)} threads burning cycles"

      "memory_leak" ->
        "Memory consumption rising - leaking #{memory_leak_rate(severity_pct)}MB every 2s"

      "latency" ->
        "Network delay injected: +#{latency_ms(severity_pct)}ms to all requests"

      "packet_loss" ->
        "#{severity_pct}% of network packets being dropped"

      "disk_failure" ->
        "Disk I/O operations failing at #{severity_pct}% rate"

      "network_partition" ->
        "Network connectivity degraded by #{severity_pct}%"

      _ ->
        "Chaos scenario active at #{severity_pct}% severity"
    end
  end

  defp cpu_thread_count(severity) when severity >= 80, do: "4"
  defp cpu_thread_count(severity) when severity >= 60, do: "3"
  defp cpu_thread_count(severity) when severity >= 40, do: "2"
  defp cpu_thread_count(_), do: "1"

  defp memory_leak_rate(severity), do: round(severity / 10)

  defp latency_ms(severity), do: round(severity * 10)

  defp extract_kind_from_message(message) when is_binary(message) do
    cond do
      String.contains?(message, "cpu") or String.contains?(message, "CPU") ->
        "cpu_spike"

      String.contains?(message, "memory") or String.contains?(message, "Memory") ->
        "memory_leak"

      String.contains?(message, "latency") or String.contains?(message, "Latency") ->
        "latency"

      String.contains?(message, "packet") ->
        "packet_loss"

      String.contains?(message, "disk") or String.contains?(message, "Disk") ->
        "disk_failure"

      String.contains?(message, "partition") or String.contains?(message, "network") ->
        "network_partition"

      true ->
        "unknown"
    end
  end

  defp extract_kind_from_message(_), do: "unknown"

  defp extract_severity_from_log(log) do
    message = log[:message] || log["message"] || ""

    cond do
      String.contains?(message, "80%") or String.contains?(message, "90%") -> 85.0
      String.contains?(message, "70%") -> 70.0
      String.contains?(message, "60%") -> 60.0
      String.contains?(message, "50%") -> 50.0
      String.contains?(message, "Stop") -> 0.0
      true -> 45.0
    end
  end

  defp format_timestamp(datetime) when is_struct(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp format_timestamp(time_str) when is_binary(time_str), do: time_str
  defp format_timestamp(_), do: "now"

  defp chaos_emoji("cpu_spike"), do: "🔥"
  defp chaos_emoji("memory_leak"), do: "💾"
  defp chaos_emoji("latency"), do: "⏱️"
  defp chaos_emoji("packet_loss"), do: "📉"
  defp chaos_emoji("disk_failure"), do: "💽"
  defp chaos_emoji("network_partition"), do: "🔌"
  defp chaos_emoji(_), do: "⚠️"

  defp chaos_bg_class(severity) when severity >= 75,
    do: "bg-rose-500/20 border border-rose-500/50 animate-pulse"

  defp chaos_bg_class(severity) when severity >= 50,
    do: "bg-orange-500/20 border border-orange-500/50"

  defp chaos_bg_class(_), do: "bg-yellow-500/20 border border-yellow-500/50"

  defp chaos_progress_class(severity) when severity >= 75,
    do: "bg-gradient-to-r from-rose-500 to-red-600 shadow-lg shadow-rose-500/50"

  defp chaos_progress_class(severity) when severity >= 50,
    do: "bg-gradient-to-r from-orange-500 to-rose-500 shadow-lg shadow-orange-500/50"

  defp chaos_progress_class(_),
    do: "bg-gradient-to-r from-yellow-500 to-orange-500 shadow-lg shadow-yellow-500/50"

  defp severity_badge_class(severity) when severity >= 75,
    do: "bg-rose-500/20 text-rose-600 dark:text-rose-400 border border-rose-500/50"

  defp severity_badge_class(severity) when severity >= 50,
    do: "bg-orange-500/20 text-orange-600 dark:text-orange-400 border border-orange-500/50"

  defp severity_badge_class(_),
    do: "bg-yellow-500/20 text-yellow-600 dark:text-yellow-400 border border-yellow-500/50"
end
