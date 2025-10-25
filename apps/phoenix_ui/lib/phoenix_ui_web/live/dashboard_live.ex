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
      send(self(), :initial_push)
    end

    topology = safe_topology()
    machines = safe_list_machines()
    prediction = safe_get_prediction()

    regions =
      case topology do
        %{"regions" => regs} when is_list(regs) -> regs
        %{regions: regs} when is_list(regs) -> regs
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
      error: nil
    }

    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_info(:initial_push, socket) do
    push_event(socket, "topology:update", %{regions: socket.assigns.regions, machines: socket.assigns.machines})
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

  @impl true
  def handle_event("create", %{"name" => name, "region" => region}, socket) do
    Task.start(fn ->
      case FlydClient.create_machine(name, region) do
        {:ok, %{"id" => id}} -> Logger.info("Created machine #{id} in #{region}")
        {:error, reason} -> Logger.warning("Create machine failed: #{inspect(reason)}")
      end
    end)

    pseudo = %{
      "id" => "pending-" <> Base.url_encode64(:crypto.strong_rand_bytes(6)),
      "name" => name,
      "region" => region,
      "status" => "pending",
      "cpu" => 0,
      "memory_mb" => 0,
      "latency" => 0
    }

    machines = [normalize_machine_payload(pseudo) | socket.assigns.machines]
    regions = update_region_count(socket.assigns.regions, region, 1)

    :telemetry.execute([:aerophoenix, :ui, :create], %{count: 1}, %{region: region, name: name})
    push_event(socket, "topology:update", %{regions: regions, machines: machines})

    {:noreply, assign(socket, machines: machines, regions: regions)}
  end

  def handle_event("select_machine", %{"id" => id}, socket), do: do_select(id, socket)
  def handle_event("select-machine", %{"id" => id}, socket), do: do_select(id, socket)

  @impl true
  def handle_event("refresh-machine", %{"id" => id}, socket) do
    Task.start(fn ->
      case FlydClient.get_machine(id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("refresh-machine failed: #{inspect(reason)}")
      end
    end)

    {:noreply, socket}
  end

  def handle_event("copy-cli", %{"cmd" => cmd}, socket) do
    push_event(socket, "copy-cli", %{cmd: cmd})
    {:noreply, socket}
  end

  @impl true
  def handle_event("action", %{"id" => id, "action" => action} = payload, socket) do
    Task.start(fn ->
      :telemetry.execute([:aerophoenix, :ui, :action], %{}, %{action: action, id: id})
      case safe_call(fn -> OrchestratorClient.action(id, Map.put(Map.drop(payload, ["id", "action"]), "action", action)) end) do
        {:ok, _} -> Logger.info("Action #{action} for #{id} succeeded")
        {:error, r} -> Logger.warning("Action #{action} for #{id} failed: #{inspect(r)}")
      end
    end)

    {:noreply, socket}
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
    if Code.ensure_loaded?(PhoenixUi.Machines) and function_exported?(PhoenixUi.Machines, :normalize_machine, 1) do
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
    cpu = parse_num(get_in_map(m, ["cpu", :cpu]) || get_in_map(m, ["cpu_percent", :cpu_percent]) || 0)
    memory_mb = parse_num(get_in_map(m, ["memory_mb", :memory_mb]) || 0)
    latency = parse_num(get_in_map(m, ["latency_ms", :latency_ms]) || get_in_map(m, ["latency", :latency]) || 0)
    updated_at = get_in_map(m, ["updated_at", :updated_at]) ||
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
end
