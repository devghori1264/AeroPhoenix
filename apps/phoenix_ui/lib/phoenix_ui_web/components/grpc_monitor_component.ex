defmodule PhoenixUiWeb.GrpcMonitorComponent do
  use PhoenixUiWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class="w-12 h-12 rounded-xl bg-gradient-to-br from-violet-500/20 to-purple-500/20 border border-violet-500/30 flex items-center justify-center">
            <.icon name="hero-bolt" class="w-6 h-6 text-violet-400" />
          </div>
          <div>
            <h3 class="text-xl font-bold text-white">gRPC Service Mesh</h3>
            <p class="text-sm text-slate-400">
              {length(@services)} services · {@total_connections} active connections
            </p>
          </div>
        </div>

        <div class="flex items-center gap-3">
          <div class="modern-badge badge-success">
            <div class="w-1.5 h-1.5 rounded-full bg-current mr-1.5 animate-pulse"></div>
            <span class="text-xs font-semibold">All Healthy</span>
          </div>
        </div>
      </div>

      <div class="data-grid grid-cols-5">
        <div class="stat-card">
          <div class="flex items-center justify-between mb-3">
            <span class="text-xs font-semibold text-slate-400 uppercase tracking-wider">
              Success Rate
            </span>
            <.icon name="hero-check-circle" class="w-5 h-5 text-emerald-400" />
          </div>
          <div class="metric-value text-3xl font-bold text-emerald-400">
            {@grpc_metrics.success_rate}%
          </div>
          <div class="mt-2 text-xs text-slate-500">
            Last 5 minutes
          </div>
        </div>

        <div class="stat-card">
          <div class="flex items-center justify-between mb-3">
            <span class="text-xs font-semibold text-slate-400 uppercase tracking-wider">
              p50 Latency
            </span>
            <.icon name="hero-bolt" class="w-5 h-5 text-violet-400" />
          </div>
          <div class="metric-value text-3xl font-bold text-violet-400">
            {@grpc_metrics.p50_latency}ms
          </div>
          <div class="mt-2 flex items-center gap-1.5 text-xs text-emerald-400">
            <.icon name="hero-arrow-trending-down" class="w-3 h-3" />
            <span>-12ms</span>
          </div>
        </div>

        <div class="stat-card">
          <div class="flex items-center justify-between mb-3">
            <span class="text-xs font-semibold text-slate-400 uppercase tracking-wider">
              p99 Latency
            </span>
            <.icon name="hero-bolt" class="w-5 h-5 text-amber-400" />
          </div>
          <div class="metric-value text-3xl font-bold text-amber-400">
            {@grpc_metrics.p99_latency}ms
          </div>
          <div class="mt-2 text-xs text-slate-500">
            Within SLA
          </div>
        </div>

        <div class="stat-card">
          <div class="flex items-center justify-between mb-3">
            <span class="text-xs font-semibold text-slate-400 uppercase tracking-wider">
              Throughput
            </span>
            <.icon name="hero-arrow-trending-up" class="w-5 h-5 text-cyan-400" />
          </div>
          <div class="metric-value text-3xl font-bold text-cyan-400">
            {@grpc_metrics.rps}
          </div>
          <div class="mt-2 text-xs text-slate-500">
            req/sec
          </div>
        </div>

        <div class="stat-card">
          <div class="flex items-center justify-between mb-3">
            <span class="text-xs font-semibold text-slate-400 uppercase tracking-wider">
              Error Rate
            </span>
            <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-rose-400" />
          </div>
          <div class="metric-value text-3xl font-bold text-rose-400">
            {@grpc_metrics.error_rate}%
          </div>
          <div class="mt-2 text-xs text-slate-500">
            0.3% threshold
          </div>
        </div>
      </div>

      <div class="space-y-4">
        <h4 class="text-sm font-semibold text-slate-400 uppercase tracking-wider">
          Service Endpoints
        </h4>

        <div class="data-grid grid-cols-2">
          <%= for service <- @services do %>
            <div class="rounded-lg bg-base-200 shadow-lg p-4">
              <div class="flex items-start justify-between mb-4">
                <div class="flex items-start gap-3 flex-1">
                  <div class={[
                    "w-10 h-10 rounded-xl border flex items-center justify-center flex-shrink-0",
                    case service.health do
                      :healthy -> "bg-emerald-500/20 border-emerald-500/30"
                      :degraded -> "bg-amber-500/20 border-amber-500/30"
                      :unhealthy -> "bg-rose-500/20 border-rose-500/30"
                      _ -> "bg-slate-500/20 border-slate-500/30"
                    end
                  ]}>
                    <%= case service.health do %>
                      <% :healthy -> %>
                        <.icon name="hero-check-circle" class="w-5 h-5 text-emerald-400" />
                      <% :degraded -> %>
                        <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-amber-400" />
                      <% :unhealthy -> %>
                        <.icon name="hero-x-circle" class="w-5 h-5 text-rose-400" />
                      <% _ -> %>
                        <.icon name="hero-question-mark-circle" class="w-5 h-5 text-slate-400" />
                    <% end %>
                  </div>

                  <div class="flex-1 min-w-0">
                    <h5 class="text-base font-bold text-white mb-1 truncate">
                      {service.name}
                    </h5>
                    <p class="text-xs text-slate-400 font-mono truncate">
                      {service.endpoint}
                    </p>
                  </div>
                </div>

                <div class={[
                  "modern-badge",
                  case service.health do
                    :healthy -> "badge-success"
                    :degraded -> "badge-warning"
                    :unhealthy -> "badge-error"
                    _ -> "badge-neutral"
                  end
                ]}>
                  {service.health |> to_string() |> String.capitalize()}
                </div>
              </div>

              <div class="grid grid-cols-2 gap-3 mb-4">
                <div class="metric-container">
                  <div class="flex items-center justify-between">
                    <span class="text-xs text-slate-500">Connections</span>
                    <span class="text-sm font-bold text-violet-400">{service.connections}</span>
                  </div>
                </div>

                <div class="metric-container">
                  <div class="flex items-center justify-between">
                    <span class="text-xs text-slate-500">Req/sec</span>
                    <span class="text-sm font-bold text-cyan-400">{service.rps}</span>
                  </div>
                </div>

                <div class="metric-container">
                  <div class="flex items-center justify-between">
                    <span class="text-xs text-slate-500">Latency</span>
                    <span class="text-sm font-bold text-white">{service.latency_ms}ms</span>
                  </div>
                </div>

                <div class="metric-container">
                  <div class="flex items-center justify-between">
                    <span class="text-xs text-slate-500">Errors</span>
                    <span class="text-sm font-bold text-rose-400">{service.error_count}</span>
                  </div>
                </div>
              </div>

              <%= if Map.get(service, :methods) do %>
                <div class="pt-3 border-t border-slate-800/50">
                  <div class="flex items-center justify-between mb-2">
                    <span class="text-xs font-semibold text-slate-400 uppercase tracking-wider">
                      Methods
                    </span>
                    <span class="text-xs text-slate-500">{length(service.methods)} available</span>
                  </div>
                  <div class="flex flex-wrap gap-2">
                    <%= for method <- Enum.take(service.methods, 6) do %>
                      <div class="px-2 py-1 rounded-lg bg-slate-800/50 border border-slate-700/50 text-xs font-mono text-slate-300">
                        {method}
                      </div>
                    <% end %>
                    <%= if length(service.methods) > 6 do %>
                      <div class="px-2 py-1 rounded-lg bg-slate-800/50 border border-slate-700/50 text-xs text-slate-500">
                        +{length(service.methods) - 6} more
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <%= if @show_connections do %>
        <div class="space-y-4">
          <div class="flex items-center justify-between">
            <h4 class="text-sm font-semibold text-slate-400 uppercase tracking-wider">
              Active Connections
            </h4>
            <button class="text-sm text-violet-400 hover:text-violet-300 font-medium flex items-center gap-1.5">
              <.icon name="hero-funnel" class="w-4 h-4" />
              <span>Filter</span>
            </button>
          </div>

          <div class="rounded-lg bg-base-200 shadow-lg overflow-hidden">
            <div class="overflow-x-auto">
              <table class="modern-table">
                <thead>
                  <tr>
                    <th>Connection ID</th>
                    <th>Service</th>
                    <th>Source Machine</th>
                    <th>Target Machine</th>
                    <th>Requests</th>
                    <th>Avg Latency</th>
                    <th>Status</th>
                    <th>Duration</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for conn <- @active_connections do %>
                    <tr>
                      <td>
                        <span class="font-mono text-xs text-violet-400">{conn.id}</span>
                      </td>
                      <td>
                        <span class="text-sm font-medium text-white">{conn.service}</span>
                      </td>
                      <td>
                        <span class="font-mono text-xs text-slate-300">{conn.source}</span>
                      </td>
                      <td>
                        <span class="font-mono text-xs text-slate-300">{conn.target}</span>
                      </td>
                      <td>
                        <span class="text-sm text-white">{conn.request_count}</span>
                      </td>
                      <td>
                        <span class="text-sm text-cyan-400">{conn.avg_latency}ms</span>
                      </td>
                      <td>
                        <div class={[
                          "modern-badge inline-flex",
                          case conn.status do
                            :active -> "badge-success"
                            :idle -> "badge-neutral"
                            :error -> "badge-error"
                            _ -> "badge-neutral"
                          end
                        ]}>
                          {conn.status |> to_string() |> String.capitalize()}
                        </div>
                      </td>
                      <td>
                        <span class="text-sm text-slate-400">{format_duration(conn.duration)}</span>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      <% end %>

      <%= if length(@recent_errors) > 0 do %>
        <div class="space-y-4">
          <div class="flex items-center justify-between">
            <h4 class="text-sm font-semibold text-slate-400 uppercase tracking-wider flex items-center gap-2">
              <span>Recent Errors</span>
              <div class="modern-badge badge-error">
                {length(@recent_errors)}
              </div>
            </h4>
            <button class="text-sm text-violet-400 hover:text-violet-300 font-medium flex items-center gap-1.5">
              <span>View All</span>
              <.icon name="hero-arrow-right" class="w-4 h-4" />
            </button>
          </div>

          <div class="rounded-lg bg-base-200 shadow-lg p-4">
            <div class="space-y-0 divide-y divide-slate-800/50">
              <%= for error <- Enum.take(@recent_errors, 5) do %>
                <div class="py-4 first:pt-0 last:pb-0">
                  <div class="flex items-start gap-4">
                    <div class="w-10 h-10 rounded-xl bg-rose-500/20 border border-rose-500/30 flex items-center justify-center flex-shrink-0">
                      <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-rose-400" />
                    </div>

                    <div class="flex-1 min-w-0">
                      <div class="flex items-center gap-3 mb-2">
                        <span class="text-sm font-semibold text-white">
                          {error.service} · {error.method}
                        </span>
                        <div class="modern-badge badge-error">
                          {error.error_code}
                        </div>
                      </div>

                      <p class="text-sm text-slate-400 mb-2">
                        {error.message}
                      </p>

                      <div class="flex items-center gap-4 text-xs text-slate-500">
                        <span class="font-mono">{error.machine}</span>
                        <span>·</span>
                        <span>{format_relative_time(error.timestamp)}</span>
                        <%= if error.retry_count > 0 do %>
                          <span>·</span>
                          <span class="text-amber-400">{error.retry_count} retries</span>
                        <% end %>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_duration(seconds) when is_number(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h"
    end
  end

  defp format_duration(_), do: "N/A"

  defp format_relative_time(timestamp) when is_struct(timestamp, DateTime) do
    diff = DateTime.diff(DateTime.utc_now(), timestamp, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp format_relative_time(_), do: "N/A"
end
