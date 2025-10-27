defmodule Orchestrator.Router do
  use Plug.Router
  require Logger
  alias Orchestrator.{Repo, Machine}

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :dispatch

  get "/api/v1/ping" do
    send_resp(conn, 200, Jason.encode!(%{"msg" => "pong from orchestrator"}))
  end

  get "/api/v1/machines" do
    machines = Repo.all(Machine)
    send_json(conn, 200, machines)
  end

  get "/api/v1/machines/:id" do
    case Repo.get(Machine, id) do
      nil -> send_json(conn, 404, %{"error" => "not_found"})
      m -> send_json(conn, 200, m)
    end
  end

  post "/api/v1/machines/:id/action" do
    {:ok, body, _} = Plug.Conn.read_body(conn)
    case Jason.decode(body) do
      {:ok, %{"action" => action} = payload} ->
        spawn(fn -> Orchestrator.MachineManager.ensure_started(id); perform_action(id, action, payload) end)
        send_json(conn, 202, %{"status" => "accepted"})
      _ -> send_json(conn, 400, %{"error" => "bad_request"})
    end
  end

  get "/api/v1/topology" do
    query = "SELECT region, count(*) as count, avg(latency_ms) as avg_latency FROM machines GROUP BY region"
    rows = Ecto.Adapters.SQL.query!(Repo, query, [])
    regions = Enum.map(rows.rows, fn [region, count, avg] -> %{"name" => region, "count" => count, "avg_latency" => avg} end)
    machines = Repo.all(Machine)
    send_json(conn, 200, %{"regions" => regions, "machines" => machines})
  end

  get "/api/v1/machines/:id/logs" do
    query = "SELECT type, payload, created_at FROM machine_events WHERE machine_id = $1 ORDER BY created_at DESC LIMIT 500"
    res = Ecto.Adapters.SQL.query!(Repo, query, [id])
    rows = Enum.map(res.rows, fn [type, payload, created_at] -> %{"type" => type, "payload" => payload, "created_at" => created_at} end)
    send_json(conn, 200, %{"logs" => rows})
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data, pretty: false))
  end

  defp perform_action(id, "restart", _payload) do
    Orchestrator.MachineManager.ensure_started(id)
    case Registry.lookup(Orchestrator.FSMRegistry, id) do
      [{pid, _}] ->
        GenServer.call(pid, {:command, "stop"})
        :timer.sleep(250)
        GenServer.call(pid, {:command, "start"})
      _ -> :ok
    end
  end

  defp perform_action(id, "migrate", %{"target" => target}) do
    Orchestrator.MachineManager.ensure_started(id)
    case Registry.lookup(Orchestrator.FSMRegistry, id) do
      [{pid, _}] -> GenServer.call(pid, {:command, "migrate", target})
      _ -> :ok
    end
  end

  defp perform_action(id, "start", _), do: GenServer.call(get_pid(id), {:command, "start"})
  defp perform_action(id, "stop", _), do: GenServer.call(get_pid(id), {:command, "stop"})
  defp get_pid(id) do
    case Registry.lookup(Orchestrator.FSMRegistry, id) do
      [{pid, _}] -> pid
      [] ->
        Orchestrator.MachineManager.ensure_started(id)
        case Registry.lookup(Orchestrator.FSMRegistry, id), do: ([{p,_}]->p; _->nil)
    end
  end
end
