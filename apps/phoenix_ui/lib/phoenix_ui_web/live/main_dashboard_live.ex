defmodule PhoenixUiWeb.MainDashboardLive do
  use PhoenixUiWeb, :live_view
  require Logger

  alias PhoenixUi.Machines
  alias PhoenixUiWeb.OrchestratorClient

  @poll_interval 2_000
  @metrics_interval 5_000

  @tabs [
    %{id: "overview", name: "Overview", icon: "hero-squares-2x2", color: "violet"},
    %{id: "migrations", name: "Migrations", icon: "hero-arrow-path", color: "cyan"},
    %{id: "grpc", name: "gRPC Services", icon: "hero-server-stack", color: "emerald"},
    %{id: "topology", name: "Multi-Region", icon: "hero-globe-americas", color: "blue"},
    %{id: "fsm", name: "State Machine", icon: "hero-cpu-chip", color: "purple"},
    %{id: "cli", name: "CLI Tools", icon: "hero-command-line", color: "slate"},
    %{id: "debugger", name: "Live Debugger", icon: "hero-bug-ant", color: "rose"},
    %{id: "replay", name: "Event Replay", icon: "hero-backward", color: "amber"},
    %{id: "optimizer", name: "Optimization", icon: "hero-chart-bar-square", color: "teal"},
    %{id: "scaling", name: "Auto-Scaling", icon: "hero-arrows-right-left", color: "indigo"},
    %{id: "flags", name: "Feature Flags", icon: "hero-flag", color: "pink"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:machines")
      Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:migrations")
      Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:chaos")
      Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:scaling")
      Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:features")

      :timer.send_interval(@poll_interval, :poll_updates)
      :timer.send_interval(@metrics_interval, :refresh_metrics)

      send(self(), :initial_load)
    end

    socket =
      socket
      |> assign(:active_tab, "overview")
      |> assign(:tabs, @tabs)
      |> assign(:machines, load_machines())
      |> assign(:active_migrations, load_active_migrations())
      |> assign(:grpc_services, load_grpc_services())
      |> assign(:topology_data, load_topology())
      |> assign(:fsm_states, load_fsm_states())
      |> assign(:recent_commands, load_recent_commands())
      |> assign(:debug_sessions, load_debug_sessions())
      |> assign(:replay_sessions, load_replay_sessions())
      |> assign(:optimization_recommendations, load_optimizations())
      |> assign(:scaling_policies, load_scaling_policies())
      |> assign(:feature_flags, load_feature_flags())
      |> assign(:system_health, %{
        cpu_usage: 0.0,
        memory_usage: 0.0,
        network_throughput: 0.0,
        active_connections: 0,
        error_rate: 0.0
      })
      |> assign(:loading, true)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket)
      when tab in [
             "overview",
             "migrations",
             "grpc",
             "topology",
             "fsm",
             "cli",
             "debugger",
             "replay",
             "optimizer",
             "scaling",
             "flags"
           ] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard?tab=#{tab}")}
  end

  def handle_event("refresh_all", _params, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> refresh_all_data()
      |> assign(:loading, false)

    {:noreply, put_flash(socket, :info, "All data refreshed successfully")}
  end

  def handle_event(
        "start_migration",
        %{"machine_id" => machine_id, "target_region" => target_region},
        socket
      ) do
    case OrchestratorClient.post("/api/v1/migrations", %{
           machine_id: machine_id,
           target_region: target_region,
           strategy: "live"
         }) do
      {:ok, %{"migration_id" => migration_id}} ->
        Logger.info("Started migration #{migration_id} for machine #{machine_id}")

        socket =
          socket
          |> assign(:active_migrations, load_active_migrations())
          |> put_flash(
            :info,
            "Migration started successfully - ID: #{String.slice(migration_id, 0, 8)}"
          )

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to start migration: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to start migration")}
    end
  end

  def handle_event("execute_optimization", %{"recommendation_id" => rec_id}, socket) do
    case OrchestratorClient.post("/api/v1/placement/execute", %{recommendation_id: rec_id}) do
      {:ok, %{"execution_id" => exec_id}} ->
        socket =
          socket
          |> assign(:optimization_recommendations, load_optimizations())
          |> put_flash(
            :info,
            "Optimization execution started - ID: #{String.slice(exec_id, 0, 8)}"
          )

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to execute optimization")}
    end
  end

  def handle_event("toggle_flag", %{"flag_key" => flag_key, "enabled" => enabled_str}, socket) do
    enabled = enabled_str == "true"

    case OrchestratorClient.post("/api/v1/flags/#{flag_key}/toggle", %{enabled: enabled}) do
      {:ok, _} ->
        socket =
          socket
          |> assign(:feature_flags, load_feature_flags())
          |> put_flash(
            :info,
            "Feature flag '#{flag_key}' #{if enabled, do: "enabled", else: "disabled"}"
          )

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle feature flag")}
    end
  end

  def handle_event("start_debug_session", %{"machine_id" => machine_id}, socket) do
    case OrchestratorClient.post("/api/v1/debug/sessions", %{machine_id: machine_id}) do
      {:ok, %{"session_id" => session_id}} ->
        socket =
          socket
          |> assign(:debug_sessions, load_debug_sessions())
          |> put_flash(:info, "Debug session started - ID: #{String.slice(session_id, 0, 8)}")

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start debug session")}
    end
  end

  @impl true
  def handle_info(:initial_load, socket) do
    socket =
      socket
      |> refresh_all_data()
      |> assign(:loading, false)

    {:noreply, socket}
  end

  def handle_info(:poll_updates, socket) do
    socket =
      socket
      |> assign(:active_migrations, load_active_migrations())
      |> assign(:system_health, load_system_health())

    {:noreply, socket}
  end

  def handle_info(:refresh_metrics, socket) do
    socket =
      socket
      |> assign(:grpc_services, load_grpc_services())
      |> assign(:scaling_policies, load_scaling_policies())
      |> assign(:optimization_recommendations, load_optimizations())

    {:noreply, socket}
  end

  def handle_info({:migration_update, migration_data}, socket) do
    migrations = update_migration_in_list(socket.assigns.active_migrations, migration_data)
    {:noreply, assign(socket, :active_migrations, migrations)}
  end

  def handle_info({:machine_update, machine_data}, socket) do
    machines = update_machine_in_list(socket.assigns.machines, machine_data)
    {:noreply, assign(socket, :machines, machines)}
  end

  def handle_info({:scaling_event, event_data}, socket) do
    Logger.info("Scaling event received: #{inspect(event_data)}")
    {:noreply, assign(socket, :scaling_policies, load_scaling_policies())}
  end

  def handle_info({:feature_flag_update, flag_data}, socket) do
    flags = update_flag_in_list(socket.assigns.feature_flags, flag_data)
    {:noreply, assign(socket, :feature_flags, flags)}
  end

  defp refresh_all_data(socket) do
    socket
    |> assign(:machines, load_machines())
    |> assign(:active_migrations, load_active_migrations())
    |> assign(:grpc_services, load_grpc_services())
    |> assign(:topology_data, load_topology())
    |> assign(:fsm_states, load_fsm_states())
    |> assign(:recent_commands, load_recent_commands())
    |> assign(:debug_sessions, load_debug_sessions())
    |> assign(:replay_sessions, load_replay_sessions())
    |> assign(:optimization_recommendations, load_optimizations())
    |> assign(:scaling_policies, load_scaling_policies())
    |> assign(:feature_flags, load_feature_flags())
    |> assign(:system_health, load_system_health())
  end

  defp load_machines do
    machines = Machines.list_all()

    if Enum.empty?(machines) do
      case safe_call(fn -> OrchestratorClient.list_machines() end) do
        {:ok, machines_from_api} when is_list(machines_from_api) -> machines_from_api
        _ -> []
      end
    else
      machines
    end
  end

  defp load_active_migrations do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/migrations/active") end) do
      {:ok, %{"migrations" => migrations}} -> migrations
      _ -> []
    end
  end

  defp load_grpc_services do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/grpc/services") end) do
      {:ok, %{"services" => services}} -> services
      _ -> []
    end
  end

  defp load_topology do
    case safe_call(fn -> OrchestratorClient.topology() end) do
      {:ok, topology} -> topology
      _ -> %{"regions" => [], "machines" => []}
    end
  end

  defp load_fsm_states do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/machines/fsm-states") end) do
      {:ok, %{"states" => states}} -> states
      _ -> []
    end
  end

  defp load_recent_commands do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/cli/history") end) do
      {:ok, %{"commands" => commands}} -> commands
      _ -> []
    end
  end

  defp load_debug_sessions do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/debug/sessions") end) do
      {:ok, %{"sessions" => sessions}} -> sessions
      _ -> []
    end
  end

  defp load_replay_sessions do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/events/replay/sessions") end) do
      {:ok, %{"sessions" => sessions}} -> sessions
      _ -> []
    end
  end

  defp load_optimizations do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/placement/recommendations") end) do
      {:ok, %{"recommendations" => recs}} -> recs
      _ -> []
    end
  end

  defp load_scaling_policies do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/scaling/policies") end) do
      {:ok, %{"policies" => policies}} -> policies
      _ -> []
    end
  end

  defp load_feature_flags do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/flags") end) do
      {:ok, %{"flags" => flags}} -> flags
      _ -> []
    end
  end

  defp load_system_health do
    case safe_call(fn -> OrchestratorClient.get("/api/v1/health") end) do
      {:ok, health} ->
        health

      _ ->
        %{
          cpu_usage: 0.0,
          memory_usage: 0.0,
          network_throughput: 0.0,
          active_connections: 0,
          error_rate: 0.0
        }
    end
  end

  defp update_migration_in_list(migrations, new_migration) do
    migration_id = new_migration["id"] || new_migration[:id]

    if Enum.any?(migrations, fn m -> (m["id"] || m[:id]) == migration_id end) do
      Enum.map(migrations, fn m ->
        if (m["id"] || m[:id]) == migration_id, do: new_migration, else: m
      end)
    else
      [new_migration | migrations]
    end
  end

  defp update_machine_in_list(machines, new_machine) do
    machine_id = new_machine["id"] || new_machine[:id]

    if Enum.any?(machines, fn m -> (m["id"] || m[:id]) == machine_id end) do
      Enum.map(machines, fn m ->
        if (m["id"] || m[:id]) == machine_id, do: new_machine, else: m
      end)
    else
      [new_machine | machines]
    end
  end

  defp update_flag_in_list(flags, new_flag) do
    flag_key = new_flag["key"] || new_flag[:key]

    if Enum.any?(flags, fn f -> (f["key"] || f[:key]) == flag_key end) do
      Enum.map(flags, fn f ->
        if (f["key"] || f[:key]) == flag_key, do: new_flag, else: f
      end)
    else
      [new_flag | flags]
    end
  end

  defp safe_call(fun) do
    try do
      fun.()
    rescue
      e ->
        Logger.warning("Safe call failed: #{inspect(e)}")
        {:error, e}
    catch
      :exit, reason ->
        Logger.warning("Safe call exit: #{inspect(reason)}")
        {:error, reason}

      value ->
        Logger.warning("Safe call caught: #{inspect(value)}")
        {:error, value}
    end
  end
end
