defmodule PhoenixUiWeb.HolodeckLive do
  use PhoenixUiWeb, :live_view
  require Logger

  alias Orchestrator.Testing.Holodeck

  @metrics_update_interval 1000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "holodeck:events")

      Process.send_after(self(), :update_metrics, @metrics_update_interval)
    end

    case Process.whereis(Holodeck) do
      nil -> Holodeck.start_link()
      _pid -> :ok
    end

    initial_state = %{
      running_scenario: nil,
      scenario_progress: 0,
      scenario_start_time: nil,
      metrics: %{
        total_spawned: 0,
        active_machines: 0,
        memory_mb: 0,
        scheduler_utilization: 0.0,
        process_count: 0
      },
      metrics_history: %{
        throughput: [],
        latency_p50: [],
        latency_p95: [],
        latency_p99: [],
        memory: []
      },
      logs: [],
      test_history: []
    }

    socket =
      socket
      |> assign(initial_state)
      |> assign(:page_title, "Holodeck Load Generator")

    {:ok, socket}
  end

  @impl true
  def handle_event("start_ramp_up", _params, socket) do
    Logger.info("Starting Ramp-Up scenario")

    Task.start(fn ->
      Holodeck.run_scenario(:ramp_up, target: 5000, interval: 30_000)
    end)

    socket =
      socket
      |> assign(:running_scenario, :ramp_up)
      |> assign(:scenario_start_time, DateTime.utc_now())
      |> add_log("Ramp-Up scenario started (target: 5000 machines)")

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_spike", _params, socket) do
    Logger.info("Starting Spike scenario")

    Task.start(fn ->
      Holodeck.run_scenario(:spike, count: 5000)
    end)

    socket =
      socket
      |> assign(:running_scenario, :spike)
      |> assign(:scenario_start_time, DateTime.utc_now())
      |> add_log("Spike scenario started (5000 machines instant)")

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_sustained", _params, socket) do
    Logger.info("Starting Sustained Load scenario")

    Task.start(fn ->
      Holodeck.run_scenario(:sustained, count: 5000, duration: 3_600_000)
    end)

    socket =
      socket
      |> assign(:running_scenario, :sustained)
      |> assign(:scenario_start_time, DateTime.utc_now())
      |> add_log("Sustained Load scenario started (5000 machines for 1 hour)")

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_chaos", _params, socket) do
    Logger.info("Starting Chaos scenario")

    Task.start(fn ->
      Holodeck.run_scenario(:chaos, count: 1000, failure_rate: 10)
    end)

    socket =
      socket
      |> assign(:running_scenario, :chaos)
      |> assign(:scenario_start_time, DateTime.utc_now())
      |> add_log("Chaos scenario started (1000 machines, 10% failure rate)")

    {:noreply, socket}
  end

  @impl true
  def handle_event("emergency_stop", _params, socket) do
    Logger.warning("Emergency stop triggered")

    Holodeck.stop_all_machines()

    socket =
      socket
      |> assign(:running_scenario, nil)
      |> add_log("Emergency stop: All machines terminated")

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_logs", _params, socket) do
    socket = assign(socket, :logs, [])
    {:noreply, socket}
  end

  @impl true
  def handle_info(:update_metrics, socket) do
    metrics = Holodeck.report_metrics()

    throughput = metrics.total_spawned - socket.assigns.metrics.total_spawned

    new_history = %{
      throughput: add_metric_point(socket.assigns.metrics_history.throughput, throughput),
      latency_p50: add_metric_point(socket.assigns.metrics_history.latency_p50, 0),
      latency_p95: add_metric_point(socket.assigns.metrics_history.latency_p95, 0),
      latency_p99: add_metric_point(socket.assigns.metrics_history.latency_p99, 0),
      memory: add_metric_point(socket.assigns.metrics_history.memory, metrics.memory_mb)
    }

    socket =
      socket
      |> assign(:metrics, metrics)
      |> assign(:metrics_history, new_history)
      |> push_event("metrics_update", %{
        throughput: throughput,
        memory_mb: metrics.memory_mb,
        active_machines: metrics.active_machines,
        scheduler_utilization: metrics.scheduler_utilization
      })

    Process.send_after(self(), :update_metrics, @metrics_update_interval)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:holodeck_event, event_type, data}, socket) do
    socket = add_log(socket, "[#{event_type}] #{inspect(data)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:scenario_complete, scenario, stats}, socket) do
    Logger.info("Scenario complete", scenario: scenario, stats: stats)

    test_result = %{
      timestamp: DateTime.utc_now(),
      scenario: scenario,
      machines: stats[:total_spawned] || 0,
      p99_latency: stats[:p99_latency] || 0,
      result: if(stats[:failed_operations] == 0, do: :pass, else: :fail)
    }

    socket =
      socket
      |> assign(:running_scenario, nil)
      |> update(:test_history, fn history -> [test_result | Enum.take(history, 9)] end)
      |> add_log("Scenario complete: #{scenario} (#{test_result.result})")

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="holodeck-container" phx-hook="HolodeckCharts" id="holodeck-dashboard">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold text-gray-900 dark:text-gray-100">
            Holodeck Load Generator
          </h1>
          <p class="text-gray-600 dark:text-gray-400 mt-1">
            Production-grade chaos engineering and load testing platform
          </p>
        </div>
        <button
          phx-click="emergency_stop"
          class="px-6 py-3 bg-red-600 hover:bg-red-700 text-white font-bold rounded-lg shadow-lg transition"
        >
          ⚠️ Emergency Stop
        </button>
      </div>

      <div class="grid grid-cols-4 gap-4 mb-6">
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <div class="flex items-center gap-3 mb-3">
            <div class="w-12 h-12 bg-blue-100 dark:bg-blue-900 rounded-lg flex items-center justify-center">
              <span class="text-2xl">📈</span>
            </div>
            <div>
              <h3 class="font-bold text-gray-900 dark:text-gray-100">Ramp-Up</h3>
              <p class="text-xs text-gray-600 dark:text-gray-400">10 → 5000</p>
            </div>
          </div>
          <p class="text-sm text-gray-700 dark:text-gray-300 mb-4">
            Gradually increase load to find breaking point
          </p>
          <button
            phx-click="start_ramp_up"
            disabled={@running_scenario != nil}
            class="w-full px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white rounded-lg transition"
          >
            {if @running_scenario == :ramp_up, do: "Running...", else: "Start"}
          </button>
        </div>

        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <div class="flex items-center gap-3 mb-3">
            <div class="w-12 h-12 bg-yellow-100 dark:bg-yellow-900 rounded-lg flex items-center justify-center">
              <span class="text-2xl">⚡</span>
            </div>
            <div>
              <h3 class="font-bold text-gray-900 dark:text-gray-100">Spike</h3>
              <p class="text-xs text-gray-600 dark:text-gray-400">5000 instant</p>
            </div>
          </div>
          <p class="text-sm text-gray-700 dark:text-gray-300 mb-4">
            Instant load (thundering herd simulation)
          </p>
          <button
            phx-click="start_spike"
            disabled={@running_scenario != nil}
            class="w-full px-4 py-2 bg-yellow-600 hover:bg-yellow-700 disabled:bg-gray-400 text-white rounded-lg transition"
          >
            {if @running_scenario == :spike, do: "Running...", else: "Start"}
          </button>
        </div>

        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <div class="flex items-center gap-3 mb-3">
            <div class="w-12 h-12 bg-green-100 dark:bg-green-900 rounded-lg flex items-center justify-center">
              <span class="text-2xl">⏱️</span>
            </div>
            <div>
              <h3 class="font-bold text-gray-900 dark:text-gray-100">Sustained</h3>
              <p class="text-xs text-gray-600 dark:text-gray-400">5000 × 1hr</p>
            </div>
          </div>
          <p class="text-sm text-gray-700 dark:text-gray-300 mb-4">
            Long-running stability test (memory leak detection)
          </p>
          <button
            phx-click="start_sustained"
            disabled={@running_scenario != nil}
            class="w-full px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-gray-400 text-white rounded-lg transition"
          >
            {if @running_scenario == :sustained, do: "Running...", else: "Start"}
          </button>
        </div>

        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <div class="flex items-center gap-3 mb-3">
            <div class="w-12 h-12 bg-red-100 dark:bg-red-900 rounded-lg flex items-center justify-center">
              <span class="text-2xl">💥</span>
            </div>
            <div>
              <h3 class="font-bold text-gray-900 dark:text-gray-100">Chaos</h3>
              <p class="text-xs text-gray-600 dark:text-gray-400">1000 + 10% kill</p>
            </div>
          </div>
          <p class="text-sm text-gray-700 dark:text-gray-300 mb-4">
            Random failures (resilience validation)
          </p>
          <button
            phx-click="start_chaos"
            disabled={@running_scenario != nil}
            class="w-full px-4 py-2 bg-red-600 hover:bg-red-700 disabled:bg-gray-400 text-white rounded-lg transition"
          >
            {if @running_scenario == :chaos, do: "Running...", else: "Start"}
          </button>
        </div>
      </div>

      <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6 mb-6">
        <h2 class="text-xl font-bold text-gray-900 dark:text-gray-100 mb-4">
          Live Metrics
        </h2>
        <div class="grid grid-cols-5 gap-6">
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Active Machines</div>
            <div class="text-3xl font-bold text-gray-900 dark:text-gray-100">
              {@metrics.active_machines}
            </div>
          </div>
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Total Spawned</div>
            <div class="text-3xl font-bold text-blue-600 dark:text-blue-400">
              {@metrics.total_spawned}
            </div>
          </div>
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Memory</div>
            <div class="text-3xl font-bold text-purple-600 dark:text-purple-400">
              {@metrics.memory_mb} MB
            </div>
          </div>
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Scheduler</div>
            <div class="text-3xl font-bold text-green-600 dark:text-green-400">
              {Float.round(@metrics.scheduler_utilization * 100, 1)}%
            </div>
          </div>
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Processes</div>
            <div class="text-3xl font-bold text-orange-600 dark:text-orange-400">
              {@metrics.process_count}
            </div>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-6 mb-6">
        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <h3 class="text-lg font-bold text-gray-900 dark:text-gray-100 mb-4">
            Throughput (machines/sec)
          </h3>
          <div id="throughput-chart" phx-update="ignore" class="h-64"></div>
        </div>

        <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <h3 class="text-lg font-bold text-gray-900 dark:text-gray-100 mb-4">
            Memory Usage (MB)
          </h3>
          <div id="memory-chart" phx-update="ignore" class="h-64"></div>
        </div>
      </div>

      <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6 mb-6">
        <h2 class="text-xl font-bold text-gray-900 dark:text-gray-100 mb-4">
          Test History
        </h2>
        <div class="overflow-x-auto">
          <table class="w-full">
            <thead class="bg-gray-100 dark:bg-gray-900">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase">
                  Timestamp
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase">
                  Scenario
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase">
                  Machines
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase">
                  P99 Latency
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase">
                  Result
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200 dark:divide-gray-700">
              <%= for result <- @test_history do %>
                <tr>
                  <td class="px-4 py-3 text-sm text-gray-900 dark:text-gray-100">
                    {format_timestamp(result.timestamp)}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-900 dark:text-gray-100">
                    {result.scenario}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-900 dark:text-gray-100">
                    {result.machines}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-900 dark:text-gray-100">
                    {result.p99_latency}ms
                  </td>
                  <td class="px-4 py-3 text-sm">
                    <%= if result.result == :pass do %>
                      <span class="px-2 py-1 bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200 rounded-full text-xs font-medium">
                        ✓ Pass
                      </span>
                    <% else %>
                      <span class="px-2 py-1 bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200 rounded-full text-xs font-medium">
                        ✗ Fail
                      </span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
              <%= if Enum.empty?(@test_history) do %>
                <tr>
                  <td colspan="5" class="px-4 py-8 text-center text-gray-500 dark:text-gray-400">
                    No test history yet. Run a scenario to see results.
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-xl font-bold text-gray-900 dark:text-gray-100">
            Test Logs
          </h2>
          <button
            phx-click="clear_logs"
            class="px-3 py-1 text-sm bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 text-gray-800 dark:text-gray-200 rounded transition"
          >
            Clear
          </button>
        </div>
        <div class="bg-gray-50 dark:bg-gray-900 rounded-lg p-4 font-mono text-sm h-64 overflow-y-auto">
          <%= for log <- Enum.reverse(@logs) do %>
            <div class="text-gray-700 dark:text-gray-300">
              {log}
            </div>
          <% end %>
          <%= if Enum.empty?(@logs) do %>
            <div class="text-gray-500 dark:text-gray-400 text-center py-8">
              No logs yet. Start a scenario to see activity.
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp add_log(socket, message) do
    timestamp = DateTime.utc_now() |> format_timestamp()
    log_entry = "[#{timestamp}] #{message}"

    new_logs = [log_entry | socket.assigns.logs] |> Enum.take(1000)

    assign(socket, :logs, new_logs)
  end

  defp add_metric_point(history, value) do
    new_point = %{timestamp: System.monotonic_time(:millisecond), value: value}

    cutoff = System.monotonic_time(:millisecond) - 60_000

    [new_point | history]
    |> Enum.filter(fn point -> point.timestamp > cutoff end)
    |> Enum.take(60)
  end

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0..7)
  end
end
