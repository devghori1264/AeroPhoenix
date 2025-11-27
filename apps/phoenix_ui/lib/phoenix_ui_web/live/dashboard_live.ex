defmodule PhoenixUiWeb.DashboardLive do
  use PhoenixUiWeb, :live_view
  require Logger

  alias PhoenixUi.Machines
  alias PhoenixUi.Predictive
  alias PhoenixUiWeb.{FlydClient, OrchestratorClient}

  @poll_interval_ms 3_000
  @max_logs 500

  @tabs [
    %{id: "overview", name: "Overview", icon: "hero-squares-2x2", color: "violet"},
    %{id: "migrations", name: "Migrations", icon: "hero-arrow-path", color: "cyan"},
    %{id: "grpc", name: "gRPC Services", icon: "hero-server-stack", color: "emerald"},
    %{id: "topology", name: "Topology", icon: "hero-globe-alt", color: "blue"},
    %{id: "fsm", name: "FSM Viewer", icon: "hero-cpu-chip", color: "purple"},
    %{id: "cli", name: "CLI Builder", icon: "hero-command-line", color: "amber"},
    %{id: "debugger", name: "Live Debugger", icon: "hero-bug-ant", color: "red"},
    %{id: "replay", name: "Event Replay", icon: "hero-clock", color: "indigo"},
    %{id: "optimizer", name: "Optimizer", icon: "hero-chart-bar", color: "green"},
    %{id: "scaling", name: "Auto-Scaling", icon: "hero-arrow-trending-up", color: "teal"},
    %{id: "flags", name: "Feature Flags", icon: "hero-flag", color: "pink"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    Logger.info("DashboardLive mount started")

    try do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:machines")
        Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:predictions")
        Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:migrations")
        Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:chaos")
        Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:scaling")
        Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:features")
        :timer.send_interval(@poll_interval_ms, :poll)
        :timer.send_interval(@poll_interval_ms, :chaos_poll)
        :timer.send_interval(5_000, :refresh_metrics)
        Phoenix.PubSub.subscribe(Orchestrator.PubSub, "debugger:sessions")
        send(self(), :initial_push)
      end

      topology = safe_topology()
      machines = safe_list_machines()
      prediction = safe_get_prediction()

      regions =
        case topology do
          %{"regions" => regs} when is_list(regs) ->
            regs

          %{regions: regs} when is_list(regs) ->
            regs

          _ ->
            [
              %{name: "us-east", code: "us-east", count: 0},
              %{name: "eu-west", code: "eu-west", count: 0},
              %{name: "ap-south", code: "ap-south", count: 0}
            ]
        end

      assigns = %{
        active_tab: "overview",
        tabs: @tabs,
        machines: machines,
        topology: topology,
        regions: regions,
        logs: [],
        prediction: prediction,
        selected: nil,
        error: nil,
        active_chaos: [],
        chaos_logs: [],
        chaos_modal_open: false,
        chaos_form: %{
          "kind" => "latency",
          "target" => "",
          "severity" => "0.5",
          "duration_ms" => "30000"
        },
        active_migrations: load_active_migrations(),
        completed_migrations: load_completed_migrations(),
        migration_stats: load_migration_stats(),
        grpc_services: load_grpc_services(),
        grpc_metrics: load_grpc_metrics(),
        active_connections: load_active_connections(),
        recent_errors: load_recent_grpc_errors(),
        show_connections: true,
        total_connections: 47,
        fsm_states: load_fsm_states(),
        transition_history: load_transition_history(),
        state_analytics: load_state_analytics(),
        command_history: load_recent_commands(),
        recent_commands: load_recent_commands(),
        debug_sessions: [],
        process_tree: [],
        replay_sessions: load_replay_sessions(),
        optimizations: load_optimizations(),
        scaling_policies: load_scaling_policies(),
        feature_flags: load_feature_flags()
      }

      Logger.info("DashboardLive mount completed successfully")
      {:ok, assign(socket, assigns)}
    rescue
      e ->
        Logger.error("DashboardLive mount failed: #{inspect(e)}")
        Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")

        {:ok,
         assign(socket, %{
           active_tab: "overview",
           tabs: @tabs,
           machines: [],
           topology: %{},
           regions: [],
           logs: [],
           prediction: %{},
           selected: nil,
           error: "Failed to load dashboard. Please refresh the page.",
           active_chaos: [],
           chaos_logs: [],
           chaos_modal_open: false,
           chaos_form: %{},
           active_migrations: [],
           completed_migrations: [],
           migration_stats: %{},
           grpc_services: [],
           grpc_metrics: %{},
           active_connections: [],
           recent_errors: [],
           show_connections: true,
           total_connections: 0,
           fsm_states: [],
           transition_history: [],
           state_analytics: %{},
           command_history: [],
           recent_commands: [],
           debug_sessions: [],
           process_tree: [],
           replay_sessions: [],
           optimizations: [],
           scaling_policies: [],
           feature_flags: []
         })}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = Map.get(params, "tab", "overview")
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def handle_info(:initial_push, socket) do
    push_event(socket, "topology:update", %{
      regions: socket.assigns.regions,
      machines: socket.assigns.machines
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:machine_update, machine_payload}, socket) do
    machine = normalize_machine_payload(machine_payload)
    machines = upsert_machine(socket.assigns.machines, machine)
    topology = safe_topology()

    push_event(socket, "topology:update", %{regions: socket.assigns.regions, machines: machines})
    {:noreply, assign(socket, machines: machines, topology: topology)}
  end

  @impl true
  def handle_info({:log_line, log}, socket) do
    logs = [log | socket.assigns.logs] |> Enum.take(@max_logs)
    push_event(socket, "new_log", %{log: log})
    {:noreply, assign(socket, logs: logs)}
  end

  @impl true
  def handle_info({:predictions, recs}, socket) do
    push_event(socket, "predictive:update", %{recs: recs})
    {:noreply, assign(socket, prediction: recs)}
  end

  @impl true
  def handle_info(:poll, socket) do
    ping_result =
      case safe_call(fn -> OrchestratorClient.ping() end) do
        {:ok, _} -> {:ok, :orch}
        _ -> safe_call(fn -> FlydClient.ping() end)
      end

    socket =
      case ping_result do
        {:ok, _} -> assign(socket, error: nil)
        {:error, reason} -> assign(socket, error: "ping failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_info(:chaos_poll, socket) do
    case OrchestratorClient.get("/api/v1/chaos/active") do
      {:ok, %{"incidents" => incidents}} ->
        socket =
          if length(incidents) != length(socket.assigns.active_chaos) do
            new_incidents = incidents -- socket.assigns.active_chaos

            new_logs =
              Enum.map(new_incidents, fn incident ->
                kind = incident["kind"] || incident[:kind] || "unknown"
                severity = incident["severity"] || incident[:severity] || 0.5

                %{
                  timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
                  message: "Started #{kind} chaos (severity: #{round(severity * 100)}%)",
                  level: "warning",
                  kind: kind,
                  severity: severity
                }
              end)

            chaos_logs = (new_logs ++ socket.assigns.chaos_logs) |> Enum.take(50)
            assign(socket, chaos_logs: chaos_logs)
          else
            socket
          end

        push_event(socket, "topology:update", %{
          regions: socket.assigns.regions,
          machines: socket.assigns.machines,
          active_chaos: incidents
        })

        {:noreply, assign(socket, active_chaos: incidents)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh_metrics, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh_after_action, socket) do
    machines = Machines.list_all()
    topology = safe_topology()

    socket =
      socket
      |> assign(machines: machines, topology: topology)
      |> push_event("topology:update", %{
        regions: socket.assigns.regions,
        machines: machines,
        active_chaos: socket.assigns.active_chaos || []
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:recommendations_received, recs}, socket) do
    {:noreply, assign(socket, prediction: recs)}
  end

  @impl true
  def handle_info({:push_event, event_name, payload}, socket) do
    {:noreply, push_event(socket, event_name, payload)}
  end

  @impl true
  def handle_info({:update_command_history, history}, socket) do
    {:noreply, assign(socket, command_history: history)}
  end

  @impl true
  def handle_info({:debug_session, _id, _msg} = event, socket) do
    case event do
      {:debug_session, _id, {:mode_changed, _}} ->
        send(self(), :refresh_debug_sessions)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh_debug_sessions, socket) do
    sessions =
      case Orchestrator.Debugger.Session.list_sessions() do
        {:ok, list} -> list
        _ -> []
      end

    {:noreply, assign(socket, debug_sessions: sessions)}
  end

  @impl true
  def handle_event("update-cost", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "create",
        %{"name" => name, "region" => region, "cpu_size" => cpu_size, "memory_mb" => memory_mb} =
          _params,
        socket
      )
      when is_binary(name) and is_binary(region) do
    memory_int = String.to_integer(memory_mb)
    do_create_machine(name, region, cpu_size, memory_int, socket)
  end

  def handle_event("create", %{"name" => name, "region" => region} = _params, socket)
      when is_binary(name) and is_binary(region) do
    do_create_machine(name, region, "dedicated-cpu-1x", 512, socket)
  end

  def handle_event("create", %{"name" => name} = _params, socket) when is_binary(name) do
    region = default_region(socket.assigns.regions)
    do_create_machine(name, region, "dedicated-cpu-1x", 512, socket)
  end

  def handle_event("create", %{"value" => encoded} = _params, socket) when is_binary(encoded) do
    params = URI.decode_query(encoded)
    name = Map.get(params, "name")
    region = Map.get(params, "region") || default_region(socket.assigns.regions)
    cpu_size = Map.get(params, "cpu_size", "dedicated-cpu-1x")
    memory_mb = Map.get(params, "memory_mb", "512") |> String.to_integer()

    cond do
      is_binary(name) and name != "" ->
        do_create_machine(name, region, cpu_size, memory_mb, socket)

      true ->
        Logger.warning("dashboard:create - invalid form payload: #{inspect(params)}")
        {:noreply, socket |> put_flash(:error, "Invalid create form")}
    end
  end

  def handle_event("create", params, socket) do
    Logger.warning("dashboard:create - unexpected params: #{inspect(params)}")
    {:noreply, socket |> put_flash(:error, "Invalid input")}
  end

  def handle_event("select_machine", %{"id" => id}, socket), do: do_select(id, socket)
  def handle_event("select-machine", %{"id" => id}, socket), do: do_select(id, socket)

  @impl true
  def handle_event("refresh-machine", %{"id" => id}, socket) do
    machine =
      Enum.find(socket.assigns.machines, fn m ->
        (m[:id] || m["id"]) == id
      end)

    machine_name =
      case machine do
        %{name: name} -> name
        %{"name" => name} -> name
        _ -> "Machine"
      end

    Task.start(fn ->
      remote_id =
        case machine do
          %{metadata: %{"remote_id" => rid}} -> rid
          %{"metadata" => %{"remote_id" => rid}} -> rid
          _ -> id
        end

      case FlydClient.get_machine(remote_id) do
        {:ok, updated_machine} ->
          send(PhoenixUi.Machines, {:machine_update, Map.put(updated_machine, "id", id)})
          Logger.info("refresh-machine succeeded for #{id}")

        {:error, reason} ->
          Logger.warning("refresh-machine failed for #{id}: #{inspect(reason)}")
      end
    end)

    {:noreply, put_flash(socket, :info, "#{machine_name} is refreshed")}
  end

  def handle_event("refresh-machine", %{"value" => _}, socket) do
    {:noreply, socket}
  end

  def handle_event("copy-cli", %{"cmd" => cmd}, socket) do
    machine_name =
      cmd
      |> String.split(" ")
      |> List.last()
      |> case do
        nil -> "Machine"
        name -> name
      end

    socket = push_event(socket, "copy-cli", %{cmd: cmd})
    {:noreply, put_flash(socket, :info, "#{machine_name} CLI command copied")}
  end

  @impl true
  def handle_event("action", %{"id" => id, "action" => action} = payload, socket) do
    machine =
      Enum.find(socket.assigns.machines, fn m ->
        (m[:id] || m["id"]) == id
      end)

    machine_name =
      case machine do
        %{name: name} -> name
        %{"name" => name} -> name
        _ -> "Machine"
      end

    live_view_pid = self()

    Task.start(fn ->
      :telemetry.execute([:aerophoenix, :ui, :action], %{}, %{action: action, id: id})

      case safe_call(fn ->
             OrchestratorClient.action(
               id,
               Map.put(Map.drop(payload, ["id", "action"]), "action", action)
             )
           end) do
        {:ok, _} ->
          Logger.info("Action #{action} for #{id} succeeded")
          Process.sleep(100)

          case OrchestratorClient.topology() do
            {:ok, topo} ->
              send(PhoenixUi.Machines, {:populate_topology, topo})
              send(live_view_pid, :refresh_after_action)

            {:error, reason} ->
              Logger.warning("Failed to refresh after action: #{inspect(reason)}")
          end

        {:error, r} ->
          Logger.warning("Action #{action} for #{id} failed: #{inspect(r)}")
      end
    end)

    nats_payload = %{
      user: "dev",
      action: action,
      id: id,
      ts: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    PhoenixUiWeb.NatsClient.publish("ui.actions", nats_payload)

    message =
      case action do
        "stop" -> "#{machine_name} is stopped"
        "restart" -> "#{machine_name} restarted"
        _ -> "#{machine_name} #{action} completed"
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    case OrchestratorClient.topology() do
      {:ok, topo} ->
        send(PhoenixUi.Machines, {:populate_topology, topo})
        {:noreply, assign(socket, machines: Machines.list_all(), topology: topo)}

      {:error, _} ->
        {:noreply, assign(socket, error: "Orchestrator unreachable")}
    end
  end

  @impl true
  def handle_event("get-recommendations", %{"machine-id" => machine_id}, socket) do
    Task.start(fn ->
      case OrchestratorClient.get("/api/v1/planner/recommend?machine_id=#{machine_id}") do
        {:ok, %{"recommendations" => recs}} ->
          send(self(), {:recommendations_received, recs})

        _ ->
          Logger.warning("Failed to get recommendations for machine #{machine_id}")
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("simulate-migration", %{"rec-id" => _rec_id}, socket) do
    {:noreply, put_flash(socket, :info, "Migration simulation started")}
  end

  @impl true
  def handle_event("apply-migration", %{"rec-id" => _rec_id}, socket) do
    {:noreply, put_flash(socket, :info, "Migration applied")}
  end

  @impl true
  def handle_event("clear-flash", _, socket) do
    {:noreply, clear_flash(socket)}
  end

  @impl true
  def handle_event("delete-machine-confirm", %{"id" => id}, socket) do
    {:noreply, push_event(socket, "confirm-delete", %{id: id})}
  end

  @impl true
  def handle_event("delete-machine", %{"id" => id}, socket) do
    machine =
      Enum.find(socket.assigns.machines, fn m ->
        (m[:id] || m["id"]) == id
      end)

    machine_name =
      case machine do
        %{name: name} -> name
        %{"name" => name} -> name
        _ -> "Machine"
      end

    case Machines.delete(id) do
      {:ok, _} ->
        updated_machines =
          Enum.reject(socket.assigns.machines, fn m ->
            (m[:id] || m["id"]) == id
          end)

        socket = assign(socket, machines: updated_machines)

        socket =
          push_event(socket, "topology:update", %{
            machines: updated_machines,
            regions: socket.assigns.regions || [],
            active_chaos: socket.assigns.active_chaos || []
          })

        {:noreply, put_flash(socket, :info, "#{machine_name} deleted")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete #{machine_name}")}
    end
  end

  @impl true
  def handle_event("open-chaos-modal", _params, socket) do
    target =
      case socket.assigns.selected do
        %{"id" => id} when is_binary(id) -> id
        %{id: id} when is_binary(id) -> id
        _ -> ""
      end

    chaos_form = %{
      "kind" => "latency",
      "target" => target,
      "severity" => "0.5",
      "duration_ms" => "30000"
    }

    {:noreply, assign(socket, chaos_modal_open: true, chaos_form: chaos_form)}
  end

  def handle_event("close-chaos-modal", _params, socket) do
    {:noreply, assign(socket, chaos_modal_open: false)}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, error: nil)}
  end

  def handle_event("modal-content-click", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("submit-chaos", params, socket) do
    scenario = %{
      kind: params["kind"],
      target: if(params["target"] != "", do: params["target"], else: nil),
      severity: String.to_float(params["severity"] || "0.5"),
      duration_ms: String.to_integer(params["duration_ms"] || "30000")
    }

    case OrchestratorClient.post("/api/v1/chaos/start", scenario) do
      {:ok, %{"status" => "started", "incident" => incident}} ->
        Logger.info("Started chaos incident #{incident["id"]}")

        chaos_log = %{
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          message:
            "Started #{scenario.kind} chaos (severity: #{round(scenario.severity * 100)}%)",
          level: "warning"
        }

        chaos_logs = [chaos_log | socket.assigns.chaos_logs] |> Enum.take(50)
        active_chaos = [incident | socket.assigns.active_chaos]

        push_event(socket, "topology:update", %{
          regions: socket.assigns.regions,
          machines: socket.assigns.machines,
          active_chaos: active_chaos
        })

        {:noreply,
         socket
         |> assign(chaos_modal_open: false, chaos_logs: chaos_logs, active_chaos: active_chaos)
         |> put_flash(:info, "Chaos test started successfully")}

      {:ok, %{"incident" => incident}} ->
        Logger.info("Started chaos incident #{incident["id"]}")

        chaos_log = %{
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          message:
            "Started #{scenario.kind} chaos (severity: #{round(scenario.severity * 100)}%)",
          level: "warning"
        }

        chaos_logs = [chaos_log | socket.assigns.chaos_logs] |> Enum.take(50)
        active_chaos = [incident | socket.assigns.active_chaos]

        push_event(socket, "topology:update", %{
          regions: socket.assigns.regions,
          machines: socket.assigns.machines,
          active_chaos: active_chaos
        })

        {:noreply,
         socket
         |> assign(chaos_modal_open: false, chaos_logs: chaos_logs, active_chaos: active_chaos)
         |> put_flash(:info, "Chaos test started successfully")}

      {:ok, response} when is_map(response) ->
        incident = Map.get(response, "incident", response)
        id = incident["id"] || Map.get(response, "id", "unknown")
        Logger.info("Started chaos incident #{id}")

        chaos_log = %{
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          message:
            "Started #{scenario.kind} chaos (severity: #{round(scenario.severity * 100)}%)",
          level: "warning"
        }

        chaos_logs = [chaos_log | socket.assigns.chaos_logs] |> Enum.take(50)
        active_chaos = [incident | socket.assigns.active_chaos]

        push_event(socket, "topology:update", %{
          regions: socket.assigns.regions,
          machines: socket.assigns.machines,
          active_chaos: active_chaos
        })

        {:noreply,
         socket
         |> assign(chaos_modal_open: false, chaos_logs: chaos_logs, active_chaos: active_chaos)
         |> put_flash(:info, "Chaos test started successfully")}

      {:error, reason} ->
        Logger.error("Failed to start chaos: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to start chaos test")}
    end
  end

  @impl true
  def handle_event("stop-chaos", %{"id" => id}, socket) do
    Task.start(fn ->
      case OrchestratorClient.post("/api/v1/chaos/stop/#{id}", %{}) do
        {:ok, _} -> Logger.info("Stopped chaos incident #{id}")
        _ -> Logger.warning("Failed to stop chaos incident #{id}")
      end
    end)

    chaos_log = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      message: "Stopped chaos incident #{String.slice(id, 0, 8)}",
      level: "info"
    }

    chaos_logs = [chaos_log | socket.assigns.chaos_logs] |> Enum.take(50)

    {:noreply, assign(socket, chaos_logs: chaos_logs)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: "/dashboard/#{tab}")}
  end

  def handle_event("start_migration", %{"machine_id" => machine_id}, socket) do
    Logger.info("Starting migration for machine #{machine_id}")
    {:noreply, socket}
  end

  def handle_event("execute_optimization", params, socket) do
    Logger.info("Executing optimization: #{inspect(params)}")
    {:noreply, socket}
  end

  def handle_event("toggle_flag", %{"flag_id" => flag_id}, socket) do
    Logger.info("Toggling feature flag #{flag_id}")
    {:noreply, socket}
  end

  def handle_event("start_debug_session", %{"machine_id" => machine_id}, socket) do
    case Orchestrator.Debugger.Session.start_session(machine_id, user_id: "dashboard_user") do
      {:ok, _session_id} ->
        Logger.info("Started debug session for machine #{machine_id}")
        send(self(), :refresh_debug_sessions)
        {:noreply, put_flash(socket, :info, "Debug session started")}

      {:error, reason} ->
        Logger.error("Failed to start debug session: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to start debug session")}
    end
  end

  defp do_create_machine(name, region, cpu_size, memory_mb, socket) do
    Task.start(fn ->
      payload = %{
        "name" => name,
        "region" => region,
        "cpu_size" => cpu_size,
        "memory_mb" => memory_mb
      }

      case safe_call(fn -> OrchestratorClient.post("/api/v1/machines", payload) end) do
        {:ok, %{"id" => id}} ->
          Logger.info("Created machine #{id} in #{region} with #{cpu_size}, #{memory_mb}MB RAM")

        {:ok, other} ->
          Logger.info("Create returned: #{inspect(other)}")

        {:error, reason} ->
          Logger.warning("Create machine failed: #{inspect(reason)}")
      end
    end)

    pseudo = %{
      "id" => "pending-" <> Base.url_encode64(:crypto.strong_rand_bytes(6)),
      "name" => name,
      "region" => region,
      "status" => "pending",
      "cpu" => 0,
      "memory_mb" => memory_mb,
      "latency" => 0,
      "metadata" => %{"cpu_size" => cpu_size}
    }

    machines = [normalize_machine_payload(pseudo) | socket.assigns.machines]
    regions = update_region_count(socket.assigns.regions, region, 1)

    :telemetry.execute([:aerophoenix, :ui, :create], %{count: 1}, %{region: region, name: name})
    push_event(socket, "topology:update", %{regions: regions, machines: machines})
    {:noreply, assign(socket, machines: machines, regions: regions)}
  end

  defp do_select(id, socket) do
    selected =
      Enum.find(socket.assigns.machines, fn
        %{"id" => i} -> i == id
        %{id: i} -> i == id
        _ -> false
      end)

    {:noreply, assign(socket, selected: selected)}
  end

  defp upsert_machine(list, new_machine) when is_list(list) do
    normalized = normalize_machine_payload(new_machine)
    existing_ids = Enum.map(list, fn m -> m[:id] || m["id"] end)

    if normalized.id in existing_ids do
      Enum.map(list, fn m ->
        if (m[:id] || m["id"]) == normalized.id, do: normalized, else: m
      end)
    else
      [normalized | list]
    end
  end

  defp update_region_count(regions, region_name, delta) do
    Enum.map(regions, fn r ->
      if r[:name] == region_name || r["name"] == region_name do
        Map.update(r, :count, Map.get(r, "count", 0) + delta, &(&1 + delta))
      else
        r
      end
    end)
  end

  defp default_region(regions) when is_list(regions) and regions != [] do
    hd(regions) |> Map.get(:name) || hd(regions) |> Map.get("name")
  end

  defp default_region(_), do: "us-east"

  defp safe_call(fun) do
    try do
      fun.()
    rescue
      e -> {:error, e}
    catch
      :exit, reason -> {:error, reason}
      reason -> {:error, reason}
    end
  end

  defp safe_topology do
    cond do
      Code.ensure_loaded?(Machines) ->
        try do
          Machines.topology()
        rescue
          _ -> %{}
        end

      true ->
        case safe_call(fn -> OrchestratorClient.topology() end) do
          {:ok, topo} -> topo
          _ -> %{}
        end
    end
  end

  defp safe_list_machines do
    cond do
      Code.ensure_loaded?(Machines) ->
        try do
          Machines.list_all()
        rescue
          _ -> []
        end

      true ->
        case safe_call(fn -> OrchestratorClient.list_machines() end) do
          {:ok, list} when is_list(list) -> Enum.map(list, &normalize_machine_payload/1)
          _ -> []
        end
    end
  end

  defp safe_get_prediction do
    try do
      if Process.whereis(Predictive) do
        Predictive.latest()
      else
        nil
      end
    rescue
      _ -> nil
    end
  end

  defp normalize_machine_payload(m) when is_map(m) do
    if Code.ensure_loaded?(PhoenixUi.Machines) and
         function_exported?(PhoenixUi.Machines, :normalize_machine, 1) do
      try do
        PhoenixUi.Machines.normalize_machine(m)
      rescue
        _ -> fallback_normalize(m)
      end
    else
      fallback_normalize(m)
    end
  end

  defp fallback_normalize(m) do
    id = get_in_map(m, ["id", :id]) || UUID.uuid4()
    name = get_in_map(m, ["name", :name]) || id
    region = get_in_map(m, ["region", :region]) || "unknown"
    status_raw = get_in_map(m, ["status", :status]) || "unknown"
    status = String.to_atom(to_string(status_raw))

    cpu =
      parse_num(get_in_map(m, ["cpu", :cpu]) || get_in_map(m, ["cpu_percent", :cpu_percent]) || 0)

    memory_mb = parse_num(get_in_map(m, ["memory_mb", :memory_mb]) || 0)

    latency =
      parse_num(
        get_in_map(m, ["latency_ms", :latency_ms]) || get_in_map(m, ["latency", :latency]) || 0
      )

    updated_at =
      get_in_map(m, ["updated_at", :updated_at]) ||
        get_in_map(m, ["created_at", :created_at]) ||
        DateTime.to_iso8601(DateTime.utc_now())

    %{
      id: id,
      name: name,
      region: region,
      status: status,
      cpu: cpu,
      memory_mb: memory_mb,
      latency: latency,
      metadata: get_in_map(m, ["metadata", :metadata]) || %{},
      updated_at: updated_at
    }
  end

  defp get_in_map(map, [k | rest]) when is_map(map) do
    key_variants = [k, if(is_binary(k), do: String.to_atom(k), else: to_string(k))]

    Enum.find_value(key_variants, fn key ->
      if Map.has_key?(map, key) do
        val = Map.get(map, key)
        if rest == [], do: val, else: get_in_map(val, rest)
      end
    end)
  end

  defp get_in_map(value, []), do: value
  defp get_in_map(_, _), do: nil

  defp parse_num(n) when is_integer(n), do: n
  defp parse_num(n) when is_float(n), do: n

  defp parse_num(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp parse_num(_), do: 0

  defp load_active_migrations do
    [
      %{
        id: "mig-#{:rand.uniform(10000)}",
        source_machine: "machine-us-east-001",
        target_machine: "machine-eu-west-002",
        status: "checkpointing",
        progress: 45,
        started_at: DateTime.add(DateTime.utc_now(), -120, :second),
        phases: [
          %{
            name: "Checkpoint",
            status: :completed,
            progress: 100,
            bytes: 1024 * 1024 * 256
          },
          %{
            name: "Memory Sync",
            status: :in_progress,
            progress: 68,
            bytes: 1024 * 1024 * 512
          },
          %{
            name: "Final Sync",
            status: :pending,
            progress: 0,
            bytes: nil
          }
        ],
        metrics: %{
          checkpoint_count: 12,
          memory_size: 1024 * 1024 * 768,
          transfer_rate: 125.4,
          eta: "1m 23s"
        }
      },
      %{
        id: "mig-#{:rand.uniform(10000)}",
        source_machine: "machine-ap-south-003",
        target_machine: "machine-us-west-004",
        status: "memory_sync",
        progress: 78,
        started_at: DateTime.add(DateTime.utc_now(), -45, :second),
        phases: [
          %{
            name: "Checkpoint",
            status: :completed,
            progress: 100,
            bytes: 1024 * 1024 * 192
          },
          %{
            name: "Memory Sync",
            status: :in_progress,
            progress: 92,
            bytes: 1024 * 1024 * 384
          },
          %{
            name: "Final Sync",
            status: :in_progress,
            progress: 45,
            bytes: 1024 * 1024 * 64
          }
        ],
        metrics: %{
          checkpoint_count: 8,
          memory_size: 1024 * 1024 * 640,
          transfer_rate: 98.7,
          eta: "42s"
        }
      }
    ]
  end

  defp load_grpc_services do
    [
      %{
        name: "MachineService",
        health: :healthy,
        endpoint: "localhost:50051",
        rps: 245,
        latency_ms: 8.5,
        connections: 12,
        error_count: 0,
        methods: [
          "CreateMachine",
          "DeleteMachine",
          "GetMachine",
          "ListMachines",
          "UpdateMachine",
          "MigrateMachine"
        ]
      },
      %{
        name: "FleetService",
        health: :healthy,
        endpoint: "localhost:50052",
        rps: 189,
        latency_ms: 12.3,
        connections: 8,
        error_count: 2,
        methods: ["GetFleetStatus", "ScaleFleet", "OptimizePlacement"]
      },
      %{
        name: "TopologyService",
        health: :healthy,
        endpoint: "localhost:50053",
        rps: 567,
        latency_ms: 3.2,
        connections: 24,
        error_count: 0,
        methods: ["GetTopology", "UpdateRegion", "ListRegions", "GetMetrics"]
      },
      %{
        name: "ChaosService",
        health: :degraded,
        endpoint: "localhost:50054",
        rps: 42,
        latency_ms: 156.7,
        connections: 3,
        error_count: 15,
        methods: ["InjectChaos", "StopChaos", "ListChaos"]
      }
    ]
  end

  defp load_completed_migrations do
    [
      %{
        id: "mig-1001",
        source_machine: "machine-us-east-005",
        target_machine: "machine-eu-west-001",
        success: true,
        duration: 3200,
        completed_at: DateTime.add(DateTime.utc_now(), -300, :second),
        total_bytes: 1024 * 1024 * 256
      },
      %{
        id: "mig-1002",
        source_machine: "machine-ap-south-002",
        target_machine: "machine-us-west-003",
        success: true,
        duration: 2800,
        completed_at: DateTime.add(DateTime.utc_now(), -1200, :second),
        total_bytes: 1024 * 1024 * 128
      },
      %{
        id: "mig-1003",
        source_machine: "machine-eu-west-007",
        target_machine: "machine-us-east-002",
        success: false,
        duration: 5100,
        completed_at: DateTime.add(DateTime.utc_now(), -2400, :second),
        total_bytes: 1024 * 1024 * 512
      }
    ]
  end

  defp load_migration_stats do
    %{
      success_rate: 99.7,
      avg_duration: 3.2,
      total_transferred: 1024 * 1024 * 1024 * 2.4
    }
  end

  defp load_grpc_metrics do
    %{
      success_rate: 99.8,
      p50_latency: 8.2,
      p99_latency: 45.7,
      rps: 1043,
      error_rate: 0.2
    }
  end

  defp load_active_connections do
    [
      %{
        id: "conn-#{:rand.uniform(10000)}",
        service: "MachineService",
        source: "machine-us-east-001",
        target: "orchestrator-001",
        request_count: 1247,
        avg_latency: 8.3,
        status: :active,
        duration: 3600
      },
      %{
        id: "conn-#{:rand.uniform(10000)}",
        service: "FleetService",
        source: "orchestrator-001",
        target: "machine-eu-west-002",
        request_count: 892,
        avg_latency: 12.1,
        status: :active,
        duration: 2400
      },
      %{
        id: "conn-#{:rand.uniform(10000)}",
        service: "TopologyService",
        source: "machine-ap-south-003",
        target: "orchestrator-002",
        request_count: 3456,
        avg_latency: 3.7,
        status: :idle,
        duration: 7200
      }
    ]
  end

  defp load_recent_grpc_errors do
    [
      %{
        service: "ChaosService",
        method: "InjectChaos",
        error_code: "DEADLINE_EXCEEDED",
        message: "Request timeout after 5000ms",
        machine: "machine-us-east-001",
        timestamp: DateTime.add(DateTime.utc_now(), -120, :second),
        retry_count: 3
      },
      %{
        service: "MachineService",
        method: "MigrateMachine",
        error_code: "UNAVAILABLE",
        message: "Target machine unreachable",
        machine: "machine-eu-west-005",
        timestamp: DateTime.add(DateTime.utc_now(), -450, :second),
        retry_count: 0
      }
    ]
  end

  defp load_fsm_states do
    [
      %{
        id: "machine-us-east-001",
        current_state: "running",
        region: "us-east",
        uptime: 3_600_000,
        created_at: DateTime.add(DateTime.utc_now(), -86400, :second),
        recent_transitions: [
          %{
            from_state: "created",
            to_state: "running",
            from_color: "violet",
            event: "start",
            timestamp: DateTime.add(DateTime.utc_now(), -3600, :second),
            duration: 1200,
            success: true,
            metadata: %{reason: "Initial startup"}
          },
          %{
            from_state: "running",
            to_state: "migrating",
            from_color: "emerald",
            event: "migrate",
            timestamp: DateTime.add(DateTime.utc_now(), -1800, :second),
            duration: 3400,
            success: true,
            metadata: %{reason: "Load balancing"}
          },
          %{
            from_state: "migrating",
            to_state: "running",
            from_color: "cyan",
            event: "complete",
            timestamp: DateTime.add(DateTime.utc_now(), -600, :second),
            duration: 800,
            success: true,
            metadata: %{reason: "Migration completed"}
          }
        ]
      },
      %{
        id: "machine-eu-west-002",
        current_state: "migrating",
        region: "eu-west",
        uptime: 7_200_000,
        created_at: DateTime.add(DateTime.utc_now(), -172_800, :second),
        recent_transitions: [
          %{
            from_state: "running",
            to_state: "migrating",
            from_color: "emerald",
            event: "migrate",
            timestamp: DateTime.add(DateTime.utc_now(), -300, :second),
            duration: 2100,
            success: true,
            metadata: %{reason: "Region optimization"}
          }
        ]
      },
      %{
        id: "machine-ap-south-003",
        current_state: "stopped",
        region: "ap-south",
        uptime: 0,
        created_at: DateTime.add(DateTime.utc_now(), -259_200, :second),
        recent_transitions: [
          %{
            from_state: "running",
            to_state: "stopped",
            from_color: "emerald",
            event: "stop",
            timestamp: DateTime.add(DateTime.utc_now(), -900, :second),
            duration: 450,
            success: true,
            metadata: %{reason: "Manual shutdown"}
          }
        ]
      }
    ]
  end

  defp load_transition_history do
    [
      %{
        machine_id: "machine-us-east-001",
        from_state: "created",
        to_state: "running",
        event: "start",
        timestamp: DateTime.add(DateTime.utc_now(), -3600, :second),
        duration: 1200,
        success: true,
        retry_count: 0
      },
      %{
        machine_id: "machine-eu-west-002",
        from_state: "running",
        to_state: "migrating",
        event: "migrate",
        timestamp: DateTime.add(DateTime.utc_now(), -1800, :second),
        duration: 3400,
        success: true,
        retry_count: 0
      },
      %{
        machine_id: "machine-ap-south-003",
        from_state: "running",
        to_state: "stopped",
        event: "stop",
        timestamp: DateTime.add(DateTime.utc_now(), -900, :second),
        duration: 450,
        success: true,
        retry_count: 0
      },
      %{
        machine_id: "machine-us-west-004",
        from_state: "migrating",
        to_state: "error",
        event: "crash",
        timestamp: DateTime.add(DateTime.utc_now(), -7200, :second),
        duration: 890,
        success: false,
        retry_count: 3
      }
    ]
  end

  defp load_state_analytics do
    %{
      "created" => %{avg_duration: 1200, total_duration: 12_000, count: 10},
      "running" => %{avg_duration: 3_600_000, total_duration: 36_000_000, count: 45},
      "migrating" => %{avg_duration: 3400, total_duration: 68_000, count: 20},
      "stopped" => %{avg_duration: 450, total_duration: 4500, count: 8},
      "error" => %{avg_duration: 890, total_duration: 2670, count: 3}
    }
  end

  defp load_recent_commands do
    [
      %{
        id: "cmd-1",
        command: "aeropctl machine create --region us-east --size small --name web-server-1",
        template_name: "Create Machine",
        timestamp: DateTime.add(DateTime.utc_now(), -300, :second),
        status: "success",
        output: "Machine created successfully: machine-us-east-001",
        favorite: false
      },
      %{
        id: "cmd-2",
        command:
          "aeropctl chaos inject latency --target machine-abc-123 --delay 200ms --duration 60s",
        template_name: "Inject Latency",
        timestamp: DateTime.add(DateTime.utc_now(), -600, :second),
        status: "success",
        output: "Chaos experiment started: chaos-xyz-789",
        favorite: true
      },
      %{
        id: "cmd-3",
        command:
          "aeropctl machine migrate machine-abc-123 --target-region eu-west --verify-checksum",
        template_name: "Migrate Machine",
        timestamp: DateTime.add(DateTime.utc_now(), -1200, :second),
        status: "failed",
        output: "Error: Target region not available",
        favorite: false
      },
      %{
        id: "cmd-4",
        command: "aeropctl machine list --region us-east --status running",
        template_name: "List Machines",
        timestamp: DateTime.add(DateTime.utc_now(), -1800, :second),
        status: "success",
        output: "Found 12 machines in us-east region",
        favorite: false
      }
    ]
  end

  defp load_replay_sessions do
    []
  end

  defp load_optimizations do
    []
  end

  defp load_scaling_policies do
    [
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
      }
    ]
  end

  defp load_feature_flags do
    [
      %{
        id: "flag-1",
        name: "live_migration_v2",
        enabled: false,
        rollout_percentage: 25,
        description: "Next-gen live migration with zero-downtime checkpointing"
      },
      %{
        id: "flag-2",
        name: "ml_placement_optimizer",
        enabled: true,
        rollout_percentage: 100,
        description: "ML-powered placement optimization for cost and latency"
      }
    ]
  end
end
