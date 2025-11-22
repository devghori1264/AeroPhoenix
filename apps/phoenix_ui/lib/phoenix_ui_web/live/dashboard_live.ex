defmodule PhoenixUiWeb.DashboardLive do
  use PhoenixUiWeb, :live_view
  require Logger

  alias PhoenixUi.Machines
  alias PhoenixUi.Predictive
  alias PhoenixUiWeb.{FlydClient, OrchestratorClient}

  @poll_interval_ms 3_000
  @max_logs 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:machines")
      Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "phoenix:predictions")
      :timer.send_interval(@poll_interval_ms, :poll)
      :timer.send_interval(@poll_interval_ms, :chaos_poll)
      :timer.send_interval(5_000, :refresh_metrics)
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
      }
    }

    {:ok, assign(socket, assigns)}
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

  defp format_log_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} ->
        "#{String.pad_leading(Integer.to_string(dt.hour), 2, "0")}:#{String.pad_leading(Integer.to_string(dt.minute), 2, "0")}:#{String.pad_leading(Integer.to_string(dt.second), 2, "0")}"

      _ ->
        "00:00:00"
    end
  end

  defp format_log_time(_), do: "00:00:00"
end
