defmodule OrchestratorWeb.FSMController do
  use OrchestratorWeb, :controller
  require Logger
  alias Orchestrator.{MachineFSM, Repo, Machine}

  def get_state(conn, %{"machine_id" => machine_id}) do
    case MachineFSM.get_state(machine_id) do
      {:ok, state} ->
        json(conn, %{
          ok: true,
          data: state
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{ok: false, error: "Machine FSM not found"})
    end
  end

  def get_history(conn, %{"machine_id" => machine_id}) do
    case MachineFSM.get_history(machine_id) do
      {:ok, history} ->
        json(conn, %{
          ok: true,
          data: %{
            machine_id: machine_id,
            transition_count: length(history),
            transitions: history
          }
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{ok: false, error: "Machine FSM not found"})
    end
  end

  def trigger_health_check(conn, %{"machine_id" => machine_id}) do
    case MachineFSM.trigger_health_check(machine_id) do
      :ok ->
        json(conn, %{
          ok: true,
          message: "Health check triggered"
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{ok: false, error: "Machine FSM not found"})
    end
  end

  def get_graph(conn, params) do
    format = Map.get(params, "format", "json")

    graph =
      case format do
        "mermaid" -> generate_mermaid_graph()
        "dot" -> generate_dot_graph()
        _ -> generate_json_graph()
      end

    content_type =
      case format do
        "mermaid" -> "text/plain"
        "dot" -> "text/vnd.graphviz"
        _ -> "application/json"
      end

    conn
    |> put_resp_content_type(content_type)
    |> send_resp(200, graph)
  end

  def get_stats(conn, _params) do
    stats = calculate_fsm_stats()

    json(conn, %{
      ok: true,
      data: stats
    })
  end

  def get_timeline(conn, %{"machine_id" => machine_id}) do
    case MachineFSM.get_history(machine_id) do
      {:ok, history} ->
        timeline = format_timeline(history, machine_id)

        json(conn, %{
          ok: true,
          data: timeline
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{ok: false, error: "Machine FSM not found"})
    end
  end

  defp generate_mermaid_graph do
    """
    stateDiagram-v2
        [*] --> created
        created --> starting: start command
        created --> destroyed: destroy command
        starting --> running: start successful
        starting --> error: start failed
        starting --> restarting: restart needed
        running --> stopping: stop command
        running --> migrating: migrate command
        running --> suspended: suspend command
        running --> health_check: periodic probe
        running --> destroyed: destroy command
        running --> restarting: crash detected
        stopping --> stopped: stop successful
        stopping --> error: stop failed
        stopped --> starting: start/resume command
        stopped --> destroyed: destroy command
        migrating --> running: migration complete
        migrating --> error: migration failed
        migrating --> stopped: migration rolled back
        suspended --> starting: resume command
        suspended --> destroyed: destroy command
        health_check --> running: healthy
        health_check --> restarting: unhealthy threshold
        health_check --> error: health check failed
        restarting --> starting: restart initiated
        restarting --> error: restart failed
        error --> restarting: retry attempt
        error --> destroyed: give up / manual destroy
        destroyed --> [*]
    """
  end

  defp generate_dot_graph do
    """
    digraph machine_fsm {
      rankdir=LR;
      node [shape=circle, style=filled, fillcolor=lightblue];
      created [fillcolor=lightgreen];
      destroyed [fillcolor=lightgray, shape=doublecircle];
      error [fillcolor=lightcoral];
      running [fillcolor=lightseagreen];
      created -> starting [label="start"];
      created -> destroyed [label="destroy"];
      starting -> running [label="success"];
      starting -> error [label="failure"];
      starting -> restarting [label="restart"];
      running -> stopping [label="stop"];
      running -> migrating [label="migrate"];
      running -> suspended [label="suspend"];
      running -> health_check [label="probe"];
      running -> destroyed [label="destroy"];
      running -> restarting [label="crash"];
      stopping -> stopped [label="success"];
      stopping -> error [label="failure"];
      stopped -> starting [label="resume"];
      stopped -> destroyed [label="destroy"];
      migrating -> running [label="complete"];
      migrating -> error [label="failure"];
      migrating -> stopped [label="rollback"];
      suspended -> starting [label="resume"];
      suspended -> destroyed [label="destroy"];
      health_check -> running [label="healthy"];
      health_check -> restarting [label="unhealthy"];
      health_check -> error [label="failed"];
      restarting -> starting [label="retry"];
      restarting -> error [label="failure"];
      error -> restarting [label="retry"];
      error -> destroyed [label="abandon"];
    }
    """
  end

  defp generate_json_graph do
    graph = %{
      states: [
        %{id: "created", label: "Created", color: "green", type: "initial"},
        %{id: "starting", label: "Starting", color: "blue", type: "transient"},
        %{id: "running", label: "Running", color: "green", type: "stable"},
        %{id: "stopping", label: "Stopping", color: "yellow", type: "transient"},
        %{id: "stopped", label: "Stopped", color: "gray", type: "stable"},
        %{id: "migrating", label: "Migrating", color: "orange", type: "transient"},
        %{id: "restarting", label: "Restarting", color: "yellow", type: "transient"},
        %{id: "suspended", label: "Suspended", color: "purple", type: "stable"},
        %{id: "health_check", label: "Health Check", color: "cyan", type: "transient"},
        %{id: "error", label: "Error", color: "red", type: "failure"},
        %{id: "destroyed", label: "Destroyed", color: "black", type: "terminal"}
      ],
      transitions: [
        %{from: "created", to: "starting", trigger: "start command"},
        %{from: "created", to: "destroyed", trigger: "destroy command"},
        %{from: "starting", to: "running", trigger: "start successful"},
        %{from: "starting", to: "error", trigger: "start failed"},
        %{from: "starting", to: "restarting", trigger: "restart needed"},
        %{from: "running", to: "stopping", trigger: "stop command"},
        %{from: "running", to: "migrating", trigger: "migrate command"},
        %{from: "running", to: "suspended", trigger: "suspend command"},
        %{from: "running", to: "health_check", trigger: "periodic probe"},
        %{from: "running", to: "destroyed", trigger: "destroy command"},
        %{from: "running", to: "restarting", trigger: "crash detected"},
        %{from: "stopping", to: "stopped", trigger: "stop successful"},
        %{from: "stopping", to: "error", trigger: "stop failed"},
        %{from: "stopped", to: "starting", trigger: "start/resume command"},
        %{from: "stopped", to: "destroyed", trigger: "destroy command"},
        %{from: "migrating", to: "running", trigger: "migration complete"},
        %{from: "migrating", to: "error", trigger: "migration failed"},
        %{from: "migrating", to: "stopped", trigger: "migration rolled back"},
        %{from: "suspended", to: "starting", trigger: "resume command"},
        %{from: "suspended", to: "destroyed", trigger: "destroy command"},
        %{from: "health_check", to: "running", trigger: "healthy"},
        %{from: "health_check", to: "restarting", trigger: "unhealthy threshold"},
        %{from: "health_check", to: "error", trigger: "health check failed"},
        %{from: "restarting", to: "starting", trigger: "restart initiated"},
        %{from: "restarting", to: "error", trigger: "restart failed"},
        %{from: "error", to: "restarting", trigger: "retry attempt"},
        %{from: "error", to: "destroyed", trigger: "give up / manual destroy"}
      ]
    }

    Jason.encode!(graph, pretty: true)
  end

  defp calculate_fsm_stats do
    machines = Repo.all(Machine)

    status_counts =
      machines
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {status, machines} -> {status, length(machines)} end)
      |> Map.new()

    region_counts =
      machines
      |> Enum.group_by(& &1.region)
      |> Enum.map(fn {region, machines} -> {region || "unknown", length(machines)} end)
      |> Map.new()

    %{
      total_machines: length(machines),
      status_distribution: status_counts,
      region_distribution: region_counts,
      timestamp: DateTime.utc_now()
    }
  end

  defp format_timeline(history, machine_id) do
    machine = Repo.get(Machine, machine_id)
    created_at = if machine, do: machine.inserted_at, else: DateTime.utc_now()

    events =
      history
      |> Enum.with_index()
      |> Enum.map(fn {transition, index} ->
        %{
          id: index,
          type: "state_transition",
          from: transition.from,
          to: transition.to,
          timestamp: transition.timestamp,
          duration_ms: transition.duration_ms,
          metadata: transition.metadata,
          offset_ms: DateTime.diff(transition.timestamp, created_at, :millisecond)
        }
      end)
      |> Enum.reverse()

    %{
      machine_id: machine_id,
      created_at: created_at,
      total_duration_ms: if(Enum.empty?(events), do: 0, else: List.last(events).offset_ms),
      event_count: length(events),
      events: events
    }
  end
end
