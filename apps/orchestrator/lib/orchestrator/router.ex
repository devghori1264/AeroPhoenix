defmodule Orchestrator.Router do
  use Plug.Router
  require Logger
  alias Orchestrator.{Repo, Machine, ChaosEngine, PredictivePlanner, PredictiveSimulator}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  defp send_json(conn, status, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(data))
  end

  defp perform_action(id, action, payload) do
    Logger.info("Performing action #{action} on machine #{id} with payload: #{inspect(payload)}")
  end

  get "/api/v1/ping" do
    send_json(conn, 200, %{msg: "pong from orchestrator"})
  end

  get "/api/v1/machines" do
    machines = Repo.all(Machine)
    send_json(conn, 200, machines)
  end

  post "/api/v1/machines" do
    {:ok, body, _} = Plug.Conn.read_body(conn)

    case Jason.decode(body) do
      {:ok, %{"name" => name, "region" => region} = params} ->
        cpu_size = Map.get(params, "cpu_size", "dedicated-cpu-1x")
        memory_mb = Map.get(params, "memory_mb", 512)

        case Orchestrator.Manager.create_machine(name, region) do
          {:ok, machine} ->
            metadata = Map.merge(machine.metadata || %{}, %{"cpu_size" => cpu_size})

            changeset =
              Ecto.Changeset.change(machine,
                memory_mb: memory_mb,
                metadata: metadata
              )

            case Repo.update(changeset) do
              {:ok, updated} -> send_json(conn, 201, updated)
              {:error, _} -> send_json(conn, 201, machine)
            end

          {:error, changeset} ->
            send_json(conn, 400, %{error: "validation_failed", details: changeset.errors})
        end

      _ ->
        send_json(conn, 400, %{error: "bad_request", message: "name and region required"})
    end
  end

  get "/api/v1/machines/:id" do
    case Repo.get(Machine, id) do
      nil -> send_json(conn, 404, %{errors: %{detail: "Not Found"}})
      m -> send_json(conn, 200, m)
    end
  end

  post "/api/v1/machines/:id/action" do
    {:ok, body, _} = Plug.Conn.read_body(conn)

    case Repo.get(Machine, id) do
      nil ->
        send_json(conn, 404, %{errors: %{detail: "Not Found"}})

      machine ->
        case Jason.decode(body) do
          {:ok, %{"action" => action} = payload} ->
            perform_action(id, action, payload)

            Task.start(fn ->
              Logger.info("Performing action #{action} on machine #{id} (#{machine.name})")

              new_status =
                case action do
                  "stop" -> "stopped"
                  "start" -> "running"
                  "restart" -> "running"
                  _ -> machine.status
                end

              changeset = Ecto.Changeset.change(machine, status: new_status)

              case Repo.update(changeset) do
                {:ok, updated} ->
                  Logger.info("Machine #{id} status updated to #{new_status}")

                  Phoenix.PubSub.broadcast(
                    Orchestrator.PubSub,
                    "machines:#{id}",
                    {:machine_updated, updated}
                  )

                {:error, reason} ->
                  Logger.error("Failed to update machine #{id}: #{inspect(reason)}")
              end
            end)

            send_json(conn, 202, %{status: "accepted", action: action, machine_id: id})

          _ ->
            send_json(conn, 400, %{error: "bad_request"})
        end
    end
  end

  get "/api/v1/topology" do
    query = """
    SELECT region, count(*) as count, avg(latency_ms) as avg_latency
    FROM machines GROUP BY region
    """

    rows = Ecto.Adapters.SQL.query!(Repo, query, [])

    regions =
      Enum.map(rows.rows, fn [region, count, avg] ->
        %{name: region, count: count, avg_latency: avg}
      end)

    machines = Repo.all(Machine)
    send_json(conn, 200, %{regions: regions, machines: machines})
  end

  get "/api/v1/machines/:id/logs" do
    query = """
    SELECT type, payload, created_at
    FROM machine_events
    WHERE machine_id = $1
    ORDER BY created_at DESC LIMIT 500
    """

    res = Ecto.Adapters.SQL.query!(Repo, query, [id])

    rows =
      Enum.map(res.rows, fn [type, payload, created_at] ->
        %{type: type, payload: payload, created_at: created_at}
      end)

    send_json(conn, 200, %{logs: rows})
  end

  post "/api/v1/chaos/start" do
    {:ok, body, _} = Plug.Conn.read_body(conn)

    with {:ok, scenario} <- Jason.decode(body),
         {:ok, incident} <- ChaosEngine.start_scenario(scenario) do
      send_json(conn, 202, %{status: "started", id: incident.id})
    else
      _ -> send_json(conn, 400, %{error: "bad_request"})
    end
  end

  post "/api/v1/chaos/stop/:id" do
    case ChaosEngine.stop_scenario(id) do
      {:ok, _} -> send_json(conn, 200, %{status: "stopped", id: id})
      {:error, :not_found} -> send_json(conn, 404, %{error: "not_found"})
      other -> send_json(conn, 500, %{error: inspect(other)})
    end
  end

  get "/api/v1/chaos/active" do
    send_json(conn, 200, %{active: ChaosEngine.list_active()})
  end

  get "/api/v1/planner/recommend" do
    machine_id = conn.query_params["machine_id"]

    case PredictivePlanner.recommend_migrations(machine_id) do
      {:ok, recs} -> send_json(conn, 200, %{recommendations: recs})
      {:error, :not_found} -> send_json(conn, 404, %{error: "machine_not_found"})
    end
  end

  post "/api/v1/planner/simulate" do
    {:ok, body, _} = Plug.Conn.read_body(conn)

    case Jason.decode(body) do
      {:ok, %{"plan" => plan}} ->
        result = PredictiveSimulator.simulate_plan(plan)
        send_json(conn, 200, %{result: result})

      _ ->
        send_json(conn, 400, %{error: "bad_request"})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
