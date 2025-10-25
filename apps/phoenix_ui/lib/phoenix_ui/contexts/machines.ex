defmodule PhoenixUi.Machines do
  use GenServer
  require Logger
  alias PhoenixUiWeb.OrchestratorClient

  @table :phoenix_ui_machines
  @metrics_table :phoenix_ui_machine_metrics
  @pubsub_topic "phoenix:machines"
  @refresh_interval_ms Application.compile_env(:phoenix_ui, :topology, [])[:refresh_interval_ms] || 1_000
  @metrics_capacity 120

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec list_all() :: [map()]
  def list_all do
    case :ets.info(@table) do
      :undefined -> []
      _ -> :ets.tab2list(@table) |> Enum.map(fn {_id, m} -> m end)
    end
  end

  @spec get(String.t()) :: {:ok, map()} | :not_found
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, v}] -> {:ok, v}
      _ -> :not_found
    end
  end

  @spec add_metric(String.t(), map()) :: :ok
  def add_metric(machine_id, metric) when is_binary(machine_id) and is_map(metric) do
    GenServer.cast(__MODULE__, {:add_metric, machine_id, metric})
  end

  @spec metrics_snapshot(String.t()) :: [map()]
  def metrics_snapshot(machine_id) do
    case :ets.lookup(@metrics_table, machine_id) do
      [{^machine_id, queue}] -> :queue.to_list(queue)
      _ -> []
    end
  end

  @spec topology() :: map()
  def topology do
    regions =
      list_all()
      |> Enum.group_by(& &1.region)
      |> Enum.map(fn {r, machines} ->
        %{name: r, count: length(machines), avg_latency: avg_latency(machines)}
      end)

    links =
      for src <- regions, dst <- regions, src != dst do
        %{source: src.name, target: dst.name, latency_ms: estimated_link_latency(src, dst)}
      end

    %{regions: regions, links: links, machines: list_all()}
  end

  def init(_init) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ets.new(@metrics_table, [:named_table, :public, read_concurrency: true])
    Phoenix.PubSub.subscribe(PhoenixUi.PubSub, @pubsub_topic)
    schedule_refresh()
    {:ok, %{}}
  end

  def handle_info(:refresh, state) do
    with {:ok, %{"machines" => machines}} <- OrchestratorClient.topology(),
          true <- is_list(machines) do
      Enum.each(machines, &upsert/1)
    else
      error -> Logger.debug("Topology refresh failed: #{inspect(error)}")
    end

    schedule_refresh()
    {:noreply, state}
  end

  def handle_info({:machine_update, machine}, state) when is_map(machine) do
    upsert(machine)
    {:noreply, state}
  end

  def handle_cast({:add_metric, id, metric}, state) do
    insert_metric(id, metric)
    {:noreply, state}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  defp upsert(%{"id" => id} = raw), do: :ets.insert(@table, {id, normalize_machine(raw)})

  defp upsert(%{id: id} = raw) when is_binary(id) do
    raw |> Map.new(fn {k, v} -> {to_string(k), v} end) |> upsert()
  end

  defp normalize_machine(m) do
    %{
      id: to_str(m["id"]),
      name: m["name"] || m["id"],
      region: m["region"] || "unknown",
      status: parse_status(m["status"]),
      cpu: to_float(m["cpu"]),
      memory_mb: round(to_float(m["memory_mb"])),
      latency: to_float(m["latency_ms"]),
      metadata: m["metadata"] || %{},
      updated_at: parse_datetime(m["updated_at"] || m["created_at"])
    }
  end

  defp to_str(nil), do: ""
  defp to_str(s) when is_binary(s), do: s
  defp to_str(v), do: to_string(v)

  defp parse_status(s) when is_atom(s), do: s
  defp parse_status(s) when is_binary(s), do: String.to_atom(s)
  defp parse_status(_), do: :unknown

  defp to_float(nil), do: 0.0
  defp to_float(n) when is_number(n), do: n * 1.0
  defp to_float(s) when is_binary(s) do
    case Float.parse(s) do
      {v, _} -> v
      :error -> 0.0
    end
  end

  defp parse_datetime(nil), do: DateTime.utc_now()
  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp insert_metric(machine_id, metric) do
    ts =
      case metric[:ts] || metric["ts"] do
        %DateTime{} = dt -> dt
        s when is_binary(s) ->
          case DateTime.from_iso8601(s), do: ({:ok, dt, _} -> dt; _ -> DateTime.utc_now())
        _ -> DateTime.utc_now()
      end

    sample = %{
      ts: DateTime.to_iso8601(ts),
      cpu: to_float(metric[:cpu] || metric["cpu"]),
      latency: to_float(metric[:latency] || metric["latency"])
    }

    case :ets.lookup(@metrics_table, machine_id) do
      [] ->
        q = :queue.new() |> :queue.in(sample)
        :ets.insert(@metrics_table, {machine_id, q})

      [{^machine_id, q}] ->
        q2 = add_to_queue(q, sample)
        :ets.insert(@metrics_table, {machine_id, q2})
    end
  end

  defp add_to_queue(q, item) do
    q2 = :queue.in(item, q)
    if :queue.len(q2) > @metrics_capacity do
      {_drop, q3} = :queue.out(q2)
      q3
    else
      q2
    end
  end

  defp avg_latency(machines) when is_list(machines) and machines != [] do
    Enum.reduce(machines, 0.0, fn m, acc -> acc + (m.latency || 0.0) end) / max(1, length(machines))
  end
  defp avg_latency(_), do: 0.0

  defp estimated_link_latency(_src, _dst), do: 100 + :rand.uniform(80)
end
