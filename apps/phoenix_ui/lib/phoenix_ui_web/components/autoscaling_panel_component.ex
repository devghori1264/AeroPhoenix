defmodule PhoenixUiWeb.AutoscalingPanelComponent do
  use PhoenixUiWeb, :live_component
  require Logger

  @metrics_window 3_600
  @forecast_horizon 1_800
  @scaling_cooldown 300

  @default_policies [
    %{
      id: "policy-cpu-scale",
      name: "CPU-Based Scaling",
      enabled: true,
      metric: "cpu_utilization",
      threshold_up: 75,
      threshold_down: 30,
      scale_up_by: 2,
      scale_down_by: 1,
      cooldown_seconds: 300,
      min_instances: 2,
      max_instances: 20,
      evaluation_periods: 3,
      priority: 1
    },
    %{
      id: "policy-latency-scale",
      name: "Latency-Based Scaling",
      enabled: true,
      metric: "p95_latency",
      threshold_up: 200,
      threshold_down: 80,
      scale_up_by: 3,
      scale_down_by: 1,
      cooldown_seconds: 180,
      min_instances: 3,
      max_instances: 30,
      evaluation_periods: 2,
      priority: 2
    },
    %{
      id: "policy-predictive",
      name: "ML Predictive Scaling",
      enabled: true,
      metric: "predicted_load",
      threshold_up: 70,
      threshold_down: 40,
      scale_up_by: 4,
      scale_down_by: 2,
      cooldown_seconds: 600,
      min_instances: 5,
      max_instances: 50,
      evaluation_periods: 1,
      priority: 3
    }
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:view_mode, "overview")
     |> assign(:selected_policy, nil)
     |> assign(:policies, @default_policies)
     |> assign(:metrics_history, [])
     |> assign(:forecast_data, [])
     |> assign(:scaling_events, [])
     |> assign(:current_capacity, %{instances: 8, cpu: 45.2, memory: 62.8, requests_per_sec: 1250})
     |> assign(:predicted_capacity, nil)
     |> assign(:show_policy_editor, false)
     |> assign(:editing_policy, nil)
     |> assign(:simulation_running, false)
     |> assign(:simulation_results, nil)
     |> assign(:time_range, "1h")
     |> assign(:alert_rules, [])
     |> assign(:active_alerts, [])
     |> assign(:manual_override_active, false)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:scaling_policies, fn -> @default_policies end)
      |> assign_new(:machines, fn -> [] end)
      |> generate_metrics_history()
      |> compute_forecast()
      |> load_recent_scaling_events()
      |> evaluate_policies()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6" phx-hook="ScalingVisualizer" id="scaling-visualizer">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-3xl font-bold text-transparent bg-clip-text bg-gradient-to-r from-teal-400 to-cyan-600">
            Auto-Scaling Intelligence
          </h2>
          <p class="text-sm text-gray-400 mt-1">
            ML-powered predictive scaling with cost optimization
          </p>
        </div>

        <div class="flex gap-2">
          <button
            :for={mode <- ["overview", "policies", "forecast", "events", "simulation"]}
            phx-click="set_view_mode"
            phx-value-mode={mode}
            phx-target={@myself}
            class={[
              "px-4 py-2 rounded-lg font-medium transition-all duration-200",
              if(@view_mode == mode,
                do: "bg-gradient-to-r from-teal-500 to-cyan-600 text-white shadow-lg",
                else: "glass-panel text-gray-300 hover:text-white hover:bg-white/10"
              )
            ]}
          >
            {mode |> String.capitalize()}
          </button>
        </div>
      </div>

      <%= if @manual_override_active do %>
        <div class="glass-panel p-4 border-l-4 border-l-amber-500 bg-amber-500/10">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <span class="text-2xl">⚠️</span>
              <div>
                <div class="text-sm font-semibold text-amber-400">Manual Override Active</div>
                <div class="text-xs text-gray-400">
                  Automatic scaling is paused. Click "Resume Auto-Scaling" to restore.
                </div>
              </div>
            </div>
            <button
              phx-click="disable_manual_override"
              phx-target={@myself}
              class="px-4 py-2 bg-amber-500 text-white rounded-lg hover:bg-amber-600 transition-colors text-sm"
            >
              Resume Auto-Scaling
            </button>
          </div>
        </div>
      <% end %>

      <%= case @view_mode do %>
        <% "overview" -> %>
          {render_overview(assigns)}
        <% "policies" -> %>
          {render_policy_manager(assigns)}
        <% "forecast" -> %>
          {render_forecast_view(assigns)}
        <% "events" -> %>
          {render_event_timeline(assigns)}
        <% "simulation" -> %>
          {render_simulation_lab(assigns)}
      <% end %>

      <%= if @show_policy_editor do %>
        {render_policy_editor(assigns)}
      <% end %>
    </div>
    """
  end

  defp render_overview(assigns) do
    ~H"""
    <div class="grid grid-cols-12 gap-6">
      <div class="col-span-12 grid grid-cols-4 gap-4">
        <div class="glass-panel p-6">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-sm text-gray-400">Active Instances</h3>
            <span class="text-2xl">🖥️</span>
          </div>
          <div class="text-3xl font-bold text-white">
            {@current_capacity.instances}
          </div>
          <div class="mt-2 flex items-center gap-2">
            <div class="flex-1 h-2 bg-gray-800 rounded-full overflow-hidden">
              <div
                class="h-full bg-gradient-to-r from-teal-500 to-cyan-500"
                style={"width: #{capacity_percentage(@current_capacity.instances, get_active_policy_max(@policies))}%"}
              >
              </div>
            </div>
            <span class="text-xs text-gray-500">
              {capacity_percentage(@current_capacity.instances, get_active_policy_max(@policies))}%
            </span>
          </div>
        </div>

        <div class="glass-panel p-6">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-sm text-gray-400">CPU Utilization</h3>
            <span class="text-2xl">⚡</span>
          </div>
          <div class="text-3xl font-bold text-cyan-400">
            {Float.round(@current_capacity.cpu, 1)}%
          </div>
          <div class="mt-2 text-sm">
            <span class={utilization_status_class(@current_capacity.cpu)}>
              {utilization_status_text(@current_capacity.cpu)}
            </span>
          </div>
        </div>

        <div class="glass-panel p-6">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-sm text-gray-400">Memory Usage</h3>
            <span class="text-2xl">💾</span>
          </div>
          <div class="text-3xl font-bold text-purple-400">
            {Float.round(@current_capacity.memory, 1)}%
          </div>
          <div class="mt-2 text-sm">
            <span class={utilization_status_class(@current_capacity.memory)}>
              {utilization_status_text(@current_capacity.memory)}
            </span>
          </div>
        </div>

        <div class="glass-panel p-6">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-sm text-gray-400">Requests/sec</h3>
            <span class="text-2xl">📊</span>
          </div>
          <div class="text-3xl font-bold text-emerald-400">
            {format_number(@current_capacity.requests_per_sec)}
          </div>
          <div class="mt-2 text-sm text-gray-400">
            <span class="text-emerald-400">↑ 12.3%</span> vs baseline
          </div>
        </div>
      </div>

      <div class="col-span-8 glass-panel p-6">
        <h3 class="text-lg font-semibold text-white mb-4">
          Real-time Metrics & Forecast
          <span class="text-sm text-gray-400 font-normal ml-2">
            (Last 1 hour + 30 min prediction)
          </span>
        </h3>
        {render_metrics_chart(assigns)}
      </div>

      <div class="col-span-4 glass-panel p-6">
        <h3 class="text-lg font-semibold text-white mb-4">Active Policies</h3>
        <div class="space-y-3">
          <%= for policy <- get_enabled_policies(@policies) do %>
            <div class="bg-gray-900/50 p-4 rounded-lg border-l-4 border-l-teal-500">
              <div class="flex items-center justify-between mb-2">
                <h4 class="text-sm font-semibold text-white">{policy.name}</h4>
                <div class="w-2 h-2 rounded-full bg-teal-500 pulse-glow"></div>
              </div>
              <div class="text-xs space-y-1">
                <div class="flex justify-between text-gray-400">
                  <span>Metric:</span>
                  <span class="text-gray-300">{metric_display_name(policy.metric)}</span>
                </div>
                <div class="flex justify-between text-gray-400">
                  <span>Threshold:</span>
                  <span class="text-teal-400">
                    ↑ {policy.threshold_up} / ↓ {policy.threshold_down}
                  </span>
                </div>
                <div class="flex justify-between text-gray-400">
                  <span>Priority:</span>
                  <span class={priority_badge_class(policy.priority)}>{policy.priority}</span>
                </div>
              </div>
            </div>
          <% end %>

          <button
            phx-click="create_new_policy"
            phx-target={@myself}
            class="w-full px-4 py-3 bg-gradient-to-r from-teal-500 to-cyan-600 text-white rounded-lg hover:shadow-lg transition-all font-medium text-sm"
          >
            + Create New Policy
          </button>
        </div>
      </div>

      <div class="col-span-12 glass-panel p-6">
        <h3 class="text-lg font-semibold text-white mb-4">Recent Scaling Events</h3>
        <div class="overflow-auto">
          <table class="w-full text-sm">
            <thead class="border-b border-gray-700">
              <tr class="text-left text-gray-400">
                <th class="py-2 px-3">Timestamp</th>
                <th class="py-2 px-3">Policy</th>
                <th class="py-2 px-3">Action</th>
                <th class="py-2 px-3">Reason</th>
                <th class="py-2 px-3 text-right">Instances</th>
                <th class="py-2 px-3">Duration</th>
                <th class="py-2 px-3">Status</th>
              </tr>
            </thead>
            <tbody>
              <%= for event <- Enum.take(@scaling_events, 10) do %>
                <tr class="border-b border-gray-800 hover:bg-white/5 transition-colors">
                  <td class="py-3 px-3 text-gray-400 text-xs font-mono">
                    {format_timestamp(event.timestamp)}
                  </td>
                  <td class="py-3 px-3 text-gray-300">{event.policy_name}</td>
                  <td class="py-3 px-3">
                    <span class={scaling_action_badge(event.action)}>
                      {event.action |> String.upcase()}
                    </span>
                  </td>
                  <td class="py-3 px-3 text-gray-400 text-xs">{event.reason}</td>
                  <td class="py-3 px-3 text-right font-mono">
                    <span class="text-gray-500">{event.from_instances}</span>
                    <span class="text-gray-600 mx-1">→</span>
                    <span class="text-white">{event.to_instances}</span>
                  </td>
                  <td class="py-3 px-3 text-gray-400 text-xs">{event.duration}</td>
                  <td class="py-3 px-3">
                    <span class={status_badge_class(event.status)}>
                      {event.status}
                    </span>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <div class="col-span-12 glass-panel p-6">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-lg font-semibold text-white">Manual Override Controls</h3>
          <div class="text-xs text-gray-500">Use with caution - bypasses automatic policies</div>
        </div>

        <div class="flex gap-4">
          <button
            phx-click="manual_scale_up"
            phx-target={@myself}
            class="flex-1 px-6 py-4 bg-gradient-to-r from-emerald-500 to-emerald-600 text-white rounded-lg hover:shadow-lg transition-all font-medium"
          >
            <div class="text-2xl mb-1">⬆️</div>
            <div class="text-sm">Scale Up (+2 instances)</div>
          </button>

          <button
            phx-click="manual_scale_down"
            phx-target={@myself}
            class="flex-1 px-6 py-4 bg-gradient-to-r from-blue-500 to-blue-600 text-white rounded-lg hover:shadow-lg transition-all font-medium"
          >
            <div class="text-2xl mb-1">⬇️</div>
            <div class="text-sm">Scale Down (-1 instance)</div>
          </button>

          <button
            phx-click="manual_set_capacity"
            phx-target={@myself}
            class="flex-1 px-6 py-4 bg-gradient-to-r from-purple-500 to-purple-600 text-white rounded-lg hover:shadow-lg transition-all font-medium"
          >
            <div class="text-2xl mb-1">🎯</div>
            <div class="text-sm">Set Exact Capacity</div>
          </button>

          <button
            phx-click="reset_to_baseline"
            phx-target={@myself}
            class="flex-1 px-6 py-4 bg-gradient-to-r from-amber-500 to-amber-600 text-white rounded-lg hover:shadow-lg transition-all font-medium"
          >
            <div class="text-2xl mb-1">🔄</div>
            <div class="text-sm">Reset to Baseline</div>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp render_policy_manager(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="glass-panel p-6">
        <div class="flex items-center justify-between mb-6">
          <h3 class="text-lg font-semibold text-white">Scaling Policies</h3>
          <button
            phx-click="create_new_policy"
            phx-target={@myself}
            class="px-4 py-2 bg-gradient-to-r from-teal-500 to-cyan-600 text-white rounded-lg hover:shadow-lg transition-all font-medium text-sm"
          >
            + New Policy
          </button>
        </div>

        <div class="space-y-4">
          <%= for policy <- @policies do %>
            <div class={[
              "p-6 rounded-lg border-2 transition-all",
              if(policy.enabled,
                do: "border-teal-500/50 bg-teal-500/5",
                else: "border-gray-700 bg-gray-900/50"
              )
            ]}>
              <div class="flex items-start justify-between mb-4">
                <div class="flex items-center gap-4">
                  <label class="relative inline-flex items-center cursor-pointer">
                    <input
                      type="checkbox"
                      checked={policy.enabled}
                      phx-click="toggle_policy"
                      phx-value-id={policy.id}
                      phx-target={@myself}
                      class="sr-only peer"
                    />
                    <div class="w-11 h-6 bg-gray-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-teal-500">
                    </div>
                  </label>

                  <div>
                    <h4 class="text-lg font-semibold text-white">{policy.name}</h4>
                    <div class="flex items-center gap-3 mt-1 text-xs text-gray-400">
                      <span>ID: {policy.id}</span>
                      <span>•</span>
                      <span>Priority: {policy.priority}</span>
                      <span>•</span>
                      <span>Cooldown: {policy.cooldown_seconds}s</span>
                    </div>
                  </div>
                </div>

                <div class="flex gap-2">
                  <button
                    phx-click="edit_policy"
                    phx-value-id={policy.id}
                    phx-target={@myself}
                    class="px-3 py-1 bg-gray-800 text-gray-300 rounded hover:bg-gray-700 transition-colors text-sm"
                  >
                    Edit
                  </button>
                  <button
                    phx-click="duplicate_policy"
                    phx-value-id={policy.id}
                    phx-target={@myself}
                    class="px-3 py-1 bg-gray-800 text-gray-300 rounded hover:bg-gray-700 transition-colors text-sm"
                  >
                    Duplicate
                  </button>
                  <button
                    phx-click="delete_policy"
                    phx-value-id={policy.id}
                    phx-target={@myself}
                    class="px-3 py-1 bg-red-500/20 text-red-400 rounded hover:bg-red-500/30 transition-colors text-sm"
                  >
                    Delete
                  </button>
                </div>
              </div>

              <div class="grid grid-cols-4 gap-4 mb-4">
                <div class="bg-gray-900/50 p-3 rounded">
                  <div class="text-xs text-gray-500 mb-1">Metric</div>
                  <div class="text-sm font-medium text-white">
                    {metric_display_name(policy.metric)}
                  </div>
                </div>
                <div class="bg-gray-900/50 p-3 rounded">
                  <div class="text-xs text-gray-500 mb-1">Scale Up Threshold</div>
                  <div class="text-sm font-medium text-red-400">≥ {policy.threshold_up}</div>
                </div>
                <div class="bg-gray-900/50 p-3 rounded">
                  <div class="text-xs text-gray-500 mb-1">Scale Down Threshold</div>
                  <div class="text-sm font-medium text-blue-400">≤ {policy.threshold_down}</div>
                </div>
                <div class="bg-gray-900/50 p-3 rounded">
                  <div class="text-xs text-gray-500 mb-1">Evaluation Periods</div>
                  <div class="text-sm font-medium text-purple-400">
                    {policy.evaluation_periods} × 60s
                  </div>
                </div>
              </div>

              <div class="grid grid-cols-4 gap-4">
                <div class="bg-gray-900/50 p-3 rounded">
                  <div class="text-xs text-gray-500 mb-1">Scale Up By</div>
                  <div class="text-sm font-medium text-emerald-400">
                    +{policy.scale_up_by} instances
                  </div>
                </div>
                <div class="bg-gray-900/50 p-3 rounded">
                  <div class="text-xs text-gray-500 mb-1">Scale Down By</div>
                  <div class="text-sm font-medium text-cyan-400">
                    -{policy.scale_down_by} instances
                  </div>
                </div>
                <div class="bg-gray-900/50 p-3 rounded">
                  <div class="text-xs text-gray-500 mb-1">Min Instances</div>
                  <div class="text-sm font-medium text-gray-300">{policy.min_instances}</div>
                </div>
                <div class="bg-gray-900/50 p-3 rounded">
                  <div class="text-xs text-gray-500 mb-1">Max Instances</div>
                  <div class="text-sm font-medium text-gray-300">{policy.max_instances}</div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <div class="glass-panel p-6">
        <h3 class="text-lg font-semibold text-white mb-4">Policy Conflict Analysis</h3>
        <%= if detect_policy_conflicts(@policies) == [] do %>
          <div class="text-center py-8 text-gray-500">
            <div class="text-4xl mb-2">✅</div>
            <p>No policy conflicts detected</p>
          </div>
        <% else %>
          <div class="space-y-3">
            <%= for conflict <- detect_policy_conflicts(@policies) do %>
              <div class="p-4 bg-amber-500/10 border-l-4 border-l-amber-500 rounded">
                <div class="text-sm font-semibold text-amber-400 mb-1">{conflict.type}</div>
                <div class="text-xs text-gray-400">{conflict.description}</div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_forecast_view(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="glass-panel p-6">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-lg font-semibold text-white">Forecast Configuration</h3>
          <div class="flex gap-2">
            <select class="bg-gray-900/50 text-white px-3 py-2 rounded-lg border border-gray-700 text-sm">
              <option>ARIMA Model</option>
              <option>LSTM Neural Network</option>
              <option>Prophet (Facebook)</option>
              <option>Exponential Smoothing</option>
            </select>
            <button
              phx-click="regenerate_forecast"
              phx-target={@myself}
              class="px-4 py-2 bg-teal-500 text-white rounded-lg hover:bg-teal-600 transition-colors text-sm"
            >
              Regenerate
            </button>
          </div>
        </div>

        <div class="grid grid-cols-3 gap-4">
          <div class="bg-gray-900/50 p-4 rounded">
            <div class="text-xs text-gray-500 mb-1">Forecast Horizon</div>
            <div class="text-2xl font-bold text-teal-400">30 minutes</div>
          </div>
          <div class="bg-gray-900/50 p-4 rounded">
            <div class="text-xs text-gray-500 mb-1">Model Accuracy (MAPE)</div>
            <div class="text-2xl font-bold text-emerald-400">94.2%</div>
          </div>
          <div class="bg-gray-900/50 p-4 rounded">
            <div class="text-xs text-gray-500 mb-1">Confidence Interval</div>
            <div class="text-2xl font-bold text-purple-400">95%</div>
          </div>
        </div>
      </div>

      <div class="glass-panel p-6">
        <h3 class="text-lg font-semibold text-white mb-4">
          Predictive Load Forecast
          <span class="text-sm text-gray-400 font-normal ml-2">
            (Historical + Predicted with confidence bands)
          </span>
        </h3>
        {render_forecast_chart(assigns)}
      </div>

      <div class="glass-panel p-6">
        <h3 class="text-lg font-semibold text-white mb-4">AI Capacity Recommendations</h3>
        <div class="grid grid-cols-3 gap-4">
          <div class="p-6 bg-gradient-to-br from-emerald-500/10 to-emerald-600/5 border border-emerald-500/30 rounded-lg">
            <div class="text-xs text-emerald-400 mb-2">Recommended Action</div>
            <div class="text-xl font-bold text-white mb-1">Scale Up</div>
            <div class="text-sm text-gray-400 mb-3">Predicted spike in 18 minutes</div>
            <div class="text-xs text-gray-500">
              Target: <span class="text-white font-medium">12 instances</span>
            </div>
          </div>

          <div class="p-6 bg-gradient-to-br from-blue-500/10 to-blue-600/5 border border-blue-500/30 rounded-lg">
            <div class="text-xs text-blue-400 mb-2">Optimal Timing</div>
            <div class="text-xl font-bold text-white mb-1">In 15 minutes</div>
            <div class="text-sm text-gray-400 mb-3">Pre-emptive scaling window</div>
            <div class="text-xs text-gray-500">
              Lead time: <span class="text-white font-medium">3 min buffer</span>
            </div>
          </div>

          <div class="p-6 bg-gradient-to-br from-purple-500/10 to-purple-600/5 border border-purple-500/30 rounded-lg">
            <div class="text-xs text-purple-400 mb-2">Cost Impact</div>
            <div class="text-xl font-bold text-white mb-1">+$2.45/hr</div>
            <div class="text-sm text-gray-400 mb-3">Additional capacity cost</div>
            <div class="text-xs text-gray-500">
              ROI: <span class="text-emerald-400 font-medium">Prevents $12.80 SLA penalty</span>
            </div>
          </div>
        </div>
      </div>

      <div class="glass-panel p-6">
        <h3 class="text-lg font-semibold text-white mb-4">Seasonality & Pattern Detection</h3>
        <div class="grid grid-cols-2 gap-6">
          <div>
            <h4 class="text-sm text-gray-400 mb-3">Daily Pattern</h4>
            {render_daily_pattern_chart(assigns)}
          </div>
          <div>
            <h4 class="text-sm text-gray-400 mb-3">Weekly Pattern</h4>
            {render_weekly_pattern_chart(assigns)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_event_timeline(assigns) do
    ~H"""
    <div class="glass-panel p-6">
      <div class="flex items-center justify-between mb-6">
        <h3 class="text-lg font-semibold text-white">Scaling Event Timeline</h3>
        <div class="flex gap-2">
          <select class="bg-gray-900/50 text-white px-3 py-2 rounded-lg border border-gray-700 text-sm">
            <option>All Events</option>
            <option>Scale Up Only</option>
            <option>Scale Down Only</option>
            <option>Failed Events</option>
          </select>
          <select class="bg-gray-900/50 text-white px-3 py-2 rounded-lg border border-gray-700 text-sm">
            <option>Last 24 hours</option>
            <option>Last 7 days</option>
            <option>Last 30 days</option>
            <option>All Time</option>
          </select>
        </div>
      </div>

      <div class="relative">
        <div class="absolute left-8 top-0 bottom-0 w-0.5 bg-gradient-to-b from-teal-500 via-cyan-500 to-teal-500">
        </div>

        <div class="space-y-6">
          <%= for event <- @scaling_events do %>
            <div class="relative pl-20">
              <div class={[
                "absolute left-6 w-5 h-5 rounded-full border-4 border-gray-950",
                event_type_color(event.action)
              ]}>
              </div>

              <div class="glass-panel p-4 hover:bg-white/5 transition-colors">
                <div class="flex items-start justify-between mb-2">
                  <div>
                    <div class="flex items-center gap-2 mb-1">
                      <h4 class="font-semibold text-white">{event.action |> String.capitalize()}</h4>
                      <span class={scaling_action_badge(event.action)}>
                        {event.from_instances} → {event.to_instances}
                      </span>
                      <span class={status_badge_class(event.status)}>
                        {event.status}
                      </span>
                    </div>
                    <div class="text-xs text-gray-400">{event.policy_name}</div>
                  </div>
                  <div class="text-xs text-gray-500 font-mono">
                    {format_timestamp(event.timestamp)}
                  </div>
                </div>

                <div class="text-sm text-gray-400 mb-2">{event.reason}</div>

                <div class="grid grid-cols-3 gap-3 text-xs">
                  <div class="bg-gray-900/50 p-2 rounded">
                    <div class="text-gray-500">Duration</div>
                    <div class="text-white font-medium">{event.duration}</div>
                  </div>
                  <div class="bg-gray-900/50 p-2 rounded">
                    <div class="text-gray-500">Triggered By</div>
                    <div class="text-white font-medium">{event.trigger_metric}</div>
                  </div>
                  <div class="bg-gray-900/50 p-2 rounded">
                    <div class="text-gray-500">Cost Impact</div>
                    <div class="text-white font-medium">{event.cost_impact}</div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp render_simulation_lab(assigns) do
    ~H"""
    <div class="grid grid-cols-12 gap-6">
      <div class="col-span-4 glass-panel p-6">
        <h3 class="text-lg font-semibold text-white mb-4">What-If Simulation</h3>

        <div class="space-y-4">
          <div>
            <label class="text-sm text-gray-400 mb-2 block">Load Pattern</label>
            <select class="w-full bg-gray-900/50 text-white px-3 py-2 rounded-lg border border-gray-700">
              <option>Gradual Ramp Up</option>
              <option>Traffic Spike</option>
              <option>Flash Crowd</option>
              <option>Thundering Herd</option>
              <option>Gradual Decline</option>
              <option>Custom Pattern</option>
            </select>
          </div>

          <div>
            <label class="text-sm text-gray-400 mb-2 block">Peak Load Multiplier</label>
            <input
              type="range"
              min="1"
              max="10"
              value="3"
              class="w-full"
            />
            <div class="text-xs text-gray-500 text-right">3× baseline</div>
          </div>

          <div>
            <label class="text-sm text-gray-400 mb-2 block">Simulation Duration</label>
            <input
              type="range"
              min="5"
              max="120"
              value="30"
              class="w-full"
            />
            <div class="text-xs text-gray-500 text-right">30 minutes</div>
          </div>

          <div>
            <label class="text-sm text-gray-400 mb-2 block">Active Policies</label>
            <div class="space-y-2">
              <%= for policy <- @policies do %>
                <label class="flex items-center gap-2 text-sm cursor-pointer">
                  <input
                    type="checkbox"
                    checked={policy.enabled}
                    class="rounded border-gray-600 bg-gray-800 text-teal-500"
                  />
                  <span class="text-gray-300">{policy.name}</span>
                </label>
              <% end %>
            </div>
          </div>

          <div>
            <label class="text-sm text-gray-400 mb-2 block">Chaos Engineering</label>
            <select class="w-full bg-gray-900/50 text-white px-3 py-2 rounded-lg border border-gray-700">
              <option>No Failures</option>
              <option>Random Instance Failures (10%)</option>
              <option>Network Latency Injection</option>
              <option>Cascading Failures</option>
              <option>Zone Outage</option>
            </select>
          </div>

          <button
            phx-click="run_simulation"
            phx-target={@myself}
            class={[
              "w-full px-4 py-3 rounded-lg hover:shadow-lg transition-all font-medium",
              if(@simulation_running,
                do: "bg-red-500 text-white",
                else: "bg-gradient-to-r from-teal-500 to-cyan-600 text-white"
              )
            ]}
          >
            <%= if @simulation_running do %>
              ⏸ Stop Simulation
            <% else %>
              ▶️ Run Simulation
            <% end %>
          </button>
        </div>
      </div>

      <div class="col-span-8">
        <%= if @simulation_results do %>
          <div class="space-y-6">
            <div class="grid grid-cols-3 gap-4">
              <div class="glass-panel p-6">
                <div class="text-sm text-gray-400 mb-1">Peak Instances Needed</div>
                <div class="text-3xl font-bold text-teal-400">
                  {@simulation_results.peak_instances}
                </div>
              </div>
              <div class="glass-panel p-6">
                <div class="text-sm text-gray-400 mb-1">SLA Violations</div>
                <div class="text-3xl font-bold text-red-400">
                  {@simulation_results.sla_violations}
                </div>
              </div>
              <div class="glass-panel p-6">
                <div class="text-sm text-gray-400 mb-1">Total Cost</div>
                <div class="text-3xl font-bold text-emerald-400">
                  ${@simulation_results.total_cost}
                </div>
              </div>
            </div>

            <div class="glass-panel p-6">
              <h3 class="text-lg font-semibold text-white mb-4">Simulation Playback</h3>
              {render_simulation_chart(assigns)}
            </div>

            <div class="glass-panel p-6">
              <h3 class="text-lg font-semibold text-white mb-4">Performance Analysis</h3>
              <div class="grid grid-cols-2 gap-4">
                <div>
                  <div class="text-sm text-gray-400 mb-2">Scaling Response Time</div>
                  <div class="flex items-center gap-2">
                    <div class="flex-1 h-2 bg-gray-800 rounded-full overflow-hidden">
                      <div class="h-full bg-teal-500" style="width: 85%"></div>
                    </div>
                    <span class="text-sm text-white">85%</span>
                  </div>
                </div>
                <div>
                  <div class="text-sm text-gray-400 mb-2">Resource Efficiency</div>
                  <div class="flex items-center gap-2">
                    <div class="flex-1 h-2 bg-gray-800 rounded-full overflow-hidden">
                      <div class="h-full bg-emerald-500" style="width: 92%"></div>
                    </div>
                    <span class="text-sm text-white">92%</span>
                  </div>
                </div>
                <div>
                  <div class="text-sm text-gray-400 mb-2">Cost Optimization</div>
                  <div class="flex items-center gap-2">
                    <div class="flex-1 h-2 bg-gray-800 rounded-full overflow-hidden">
                      <div class="h-full bg-cyan-500" style="width: 78%"></div>
                    </div>
                    <span class="text-sm text-white">78%</span>
                  </div>
                </div>
                <div>
                  <div class="text-sm text-gray-400 mb-2">SLA Compliance</div>
                  <div class="flex items-center gap-2">
                    <div class="flex-1 h-2 bg-gray-800 rounded-full overflow-hidden">
                      <div class="h-full bg-purple-500" style="width: 97%"></div>
                    </div>
                    <span class="text-sm text-white">97%</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% else %>
          <div class="glass-panel p-6 h-full flex items-center justify-center text-gray-500">
            <div class="text-center">
              <div class="text-6xl mb-4">🧪</div>
              <p class="text-lg">No simulation running</p>
              <p class="text-sm mt-2">Configure parameters and click "Run Simulation"</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_policy_editor(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/60 z-50 flex items-center justify-center">
      <div class="glass-panel w-full max-w-3xl p-6 shadow-2xl border border-teal-500/30 max-h-[90vh] overflow-auto">
        <div class="flex items-center justify-between mb-6">
          <h3 class="text-xl font-bold text-white">
            {if @editing_policy, do: "Edit Policy", else: "Create New Policy"}
          </h3>
          <button
            phx-click="close_policy_editor"
            phx-target={@myself}
            class="text-gray-400 hover:text-white transition-colors text-2xl"
          >
            ×
          </button>
        </div>

        <div class="space-y-4">
          <div class="text-center py-12 text-gray-500 text-sm">
            Policy editor form with validation
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp generate_metrics_history(socket) do
    num_points = div(@metrics_window, 60)

    history =
      Enum.map(0..num_points, fn i ->
        base_cpu = 45 + :math.sin(i / 10) * 15

        %{
          timestamp: DateTime.utc_now() |> DateTime.add(-@metrics_window + i * 60, :second),
          cpu: base_cpu + :rand.uniform() * 10,
          memory: 60 + :rand.uniform() * 15,
          requests_per_sec: 1000 + trunc(:math.sin(i / 8) * 400)
        }
      end)

    assign(socket, :metrics_history, history)
  end

  defp compute_forecast(socket) do
    last_timestamp = DateTime.utc_now()
    num_forecast_points = div(@forecast_horizon, 60)

    forecast =
      Enum.map(1..num_forecast_points, fn i ->
        predicted_cpu = 55 + :math.sin(i / 5) * 20

        %{
          timestamp: DateTime.add(last_timestamp, i * 60, :second),
          predicted_cpu: predicted_cpu,
          confidence_lower: predicted_cpu - 8,
          confidence_upper: predicted_cpu + 8
        }
      end)

    assign(socket, :forecast_data, forecast)
  end

  defp load_recent_scaling_events(socket) do
    events = [
      %{
        timestamp: DateTime.utc_now() |> DateTime.add(-7200, :second),
        policy_name: "CPU-Based Scaling",
        action: "scale_up",
        reason: "CPU utilization exceeded 75% for 3 consecutive periods",
        from_instances: 6,
        to_instances: 8,
        duration: "2m 34s",
        status: "completed",
        trigger_metric: "cpu_utilization",
        cost_impact: "+$1.20/hr"
      },
      %{
        timestamp: DateTime.utc_now() |> DateTime.add(-14400, :second),
        policy_name: "ML Predictive Scaling",
        action: "scale_up",
        reason: "Predicted load spike detected 15 minutes ahead",
        from_instances: 5,
        to_instances: 6,
        duration: "1m 52s",
        status: "completed",
        trigger_metric: "predicted_load",
        cost_impact: "+$0.60/hr"
      },
      %{
        timestamp: DateTime.utc_now() |> DateTime.add(-21600, :second),
        policy_name: "Latency-Based Scaling",
        action: "scale_up",
        reason: "P95 latency exceeded 200ms threshold",
        from_instances: 4,
        to_instances: 5,
        duration: "2m 15s",
        status: "completed",
        trigger_metric: "p95_latency",
        cost_impact: "+$0.60/hr"
      }
    ]

    assign(socket, :scaling_events, events)
  end

  defp evaluate_policies(socket) do
    last_event_time =
      socket.assigns.scaling_events
      |> List.first()
      |> case do
        nil -> nil
        event -> event.timestamp
      end

    within_cooldown =
      case last_event_time do
        nil ->
          false

        timestamp ->
          seconds_since_last_event = DateTime.diff(DateTime.utc_now(), timestamp, :second)
          seconds_since_last_event < @scaling_cooldown
      end

    socket
    |> assign(:within_cooldown, within_cooldown)
    |> assign(
      :cooldown_remaining,
      (fn ->
         case {within_cooldown, last_event_time} do
           {true, timestamp} ->
             remaining = @scaling_cooldown - DateTime.diff(DateTime.utc_now(), timestamp, :second)
             max(0, remaining)

           _ ->
             0
         end
       end).()
    )
  end

  defp get_enabled_policies(policies) do
    Enum.filter(policies, & &1.enabled)
  end

  defp get_active_policy_max(policies) do
    policies
    |> get_enabled_policies()
    |> Enum.map(& &1.max_instances)
    |> Enum.max(fn -> 20 end)
  end

  defp detect_policy_conflicts(_policies) do
    []
  end

  @impl true
  def handle_event("set_view_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, view_mode: mode)}
  end

  def handle_event("toggle_policy", %{"id" => id}, socket) do
    policies =
      Enum.map(socket.assigns.policies, fn policy ->
        if policy.id == id do
          %{policy | enabled: !policy.enabled}
        else
          policy
        end
      end)

    {:noreply, assign(socket, policies: policies)}
  end

  def handle_event("create_new_policy", _params, socket) do
    {:noreply, assign(socket, show_policy_editor: true, editing_policy: nil)}
  end

  def handle_event("edit_policy", %{"id" => id}, socket) do
    policy = Enum.find(socket.assigns.policies, &(&1.id == id))
    {:noreply, assign(socket, show_policy_editor: true, editing_policy: policy)}
  end

  def handle_event("close_policy_editor", _params, socket) do
    {:noreply, assign(socket, show_policy_editor: false, editing_policy: nil)}
  end

  def handle_event("manual_scale_up", _params, socket) do
    current = socket.assigns.current_capacity
    new_capacity = %{current | instances: current.instances + 2}

    socket =
      socket
      |> assign(:current_capacity, new_capacity)
      |> assign(:manual_override_active, true)

    {:noreply, socket}
  end

  def handle_event("manual_scale_down", _params, socket) do
    current = socket.assigns.current_capacity
    new_capacity = %{current | instances: max(current.instances - 1, 2)}

    socket =
      socket
      |> assign(:current_capacity, new_capacity)
      |> assign(:manual_override_active, true)

    {:noreply, socket}
  end

  def handle_event("disable_manual_override", _params, socket) do
    {:noreply, assign(socket, manual_override_active: false)}
  end

  def handle_event("run_simulation", _params, socket) do
    if socket.assigns.simulation_running do
      {:noreply, assign(socket, simulation_running: false, simulation_results: nil)}
    else
      results = %{
        peak_instances: 14,
        sla_violations: 2,
        total_cost: 24.50
      }

      {:noreply, assign(socket, simulation_running: true, simulation_results: results)}
    end
  end

  defp render_metrics_chart(assigns) do
    ~H"""
    <div class="h-80 bg-gray-900/50 rounded-lg p-4 flex items-center justify-center text-gray-500 text-sm">
      Multi-line chart: CPU, Memory, Requests/sec + Forecast (Chart.js)
    </div>
    """
  end

  defp render_forecast_chart(assigns) do
    ~H"""
    <div class="h-96 bg-gray-900/50 rounded-lg p-4 flex items-center justify-center text-gray-500 text-sm">
      ARIMA forecast with confidence bands (Chart.js with time-series plugin)
    </div>
    """
  end

  defp render_daily_pattern_chart(assigns) do
    ~H"""
    <div class="h-48 bg-gray-900/50 rounded-lg p-4 flex items-center justify-center text-gray-500 text-sm">
      24-hour heatmap
    </div>
    """
  end

  defp render_weekly_pattern_chart(assigns) do
    ~H"""
    <div class="h-48 bg-gray-900/50 rounded-lg p-4 flex items-center justify-center text-gray-500 text-sm">
      7-day pattern
    </div>
    """
  end

  defp render_simulation_chart(assigns) do
    ~H"""
    <div class="h-64 bg-gray-900/50 rounded-lg p-4 flex items-center justify-center text-gray-500 text-sm">
      Simulation timeline playback
    </div>
    """
  end

  defp capacity_percentage(current, max) when max > 0 do
    trunc(current / max * 100)
  end

  defp capacity_percentage(_, _), do: 0

  defp metric_display_name("cpu_utilization"), do: "CPU Utilization"
  defp metric_display_name("p95_latency"), do: "P95 Latency"
  defp metric_display_name("predicted_load"), do: "Predicted Load (ML)"
  defp metric_display_name(metric), do: metric

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_timestamp(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp utilization_status_class(val) when val > 80, do: "text-red-400"
  defp utilization_status_class(val) when val > 60, do: "text-amber-400"
  defp utilization_status_class(_), do: "text-emerald-400"

  defp utilization_status_text(val) when val > 80, do: "High Utilization"
  defp utilization_status_text(val) when val > 60, do: "Moderate"
  defp utilization_status_text(_), do: "Healthy"

  defp priority_badge_class(1), do: "text-red-400 font-bold"
  defp priority_badge_class(2), do: "text-amber-400 font-bold"
  defp priority_badge_class(_), do: "text-gray-400"

  defp scaling_action_badge("scale_up"),
    do: "px-2 py-1 rounded text-xs bg-emerald-500/20 text-emerald-400 font-medium"

  defp scaling_action_badge("scale_down"),
    do: "px-2 py-1 rounded text-xs bg-blue-500/20 text-blue-400 font-medium"

  defp scaling_action_badge(_), do: "px-2 py-1 rounded text-xs bg-gray-700/50 text-gray-400"

  defp status_badge_class("completed"),
    do: "px-2 py-1 rounded text-xs bg-emerald-500/20 text-emerald-400"

  defp status_badge_class("in_progress"),
    do: "px-2 py-1 rounded text-xs bg-blue-500/20 text-blue-400"

  defp status_badge_class("failed"), do: "px-2 py-1 rounded text-xs bg-red-500/20 text-red-400"
  defp status_badge_class(_), do: "px-2 py-1 rounded text-xs bg-gray-700/50 text-gray-400"

  defp event_type_color("scale_up"), do: "bg-emerald-500"
  defp event_type_color("scale_down"), do: "bg-blue-500"
  defp event_type_color(_), do: "bg-gray-500"
end
