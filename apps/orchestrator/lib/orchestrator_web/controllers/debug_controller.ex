defmodule OrchestratorWeb.DebugController do
  use OrchestratorWeb, :controller
  require Logger
  alias Orchestrator.{Repo, Machine}

  def metrics(conn, %{"id" => machine_id}) do
    case Repo.get(Machine, machine_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Machine not found"})

      machine ->
        metrics = fetch_machine_metrics(machine)
        json(conn, metrics)
    end
  end

  def threads(conn, %{"id" => machine_id} = params) do
    case Repo.get(Machine, machine_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Machine not found"})

      machine ->
        include_stacks = params["stacks"] == "true"
        threads = fetch_machine_threads(machine, include_stacks)

        json(conn, %{
          machine_id: machine.id,
          threads: threads,
          count: length(threads)
        })
    end
  end

  def network(conn, %{"id" => machine_id} = params) do
    case Repo.get(Machine, machine_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Machine not found"})

      machine ->
        listening_only = params["listening"] == "true"
        protocol_filter = params["protocol"]
        connections = fetch_machine_connections(machine, listening_only, protocol_filter)

        json(conn, %{
          machine_id: machine.id,
          connections: connections,
          count: length(connections)
        })
    end
  end

  def file_descriptors(conn, %{"id" => machine_id} = params) do
    case Repo.get(Machine, machine_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Machine not found"})

      machine ->
        type_filter = params["type"]
        fds = fetch_machine_file_descriptors(machine, type_filter)

        types_summary =
          Enum.reduce(fds, %{files: 0, sockets: 0, pipes: 0, other: 0}, fn fd, acc ->
            case fd.type do
              "file" -> %{acc | files: acc.files + 1}
              "socket" -> %{acc | sockets: acc.sockets + 1}
              "pipe" -> %{acc | pipes: acc.pipes + 1}
              _ -> %{acc | other: acc.other + 1}
            end
          end)

        json(conn, %{
          machine_id: machine.id,
          file_descriptors: fds,
          types: types_summary,
          total: length(fds)
        })
    end
  end

  defp fetch_machine_metrics(machine) do
    %{
      machine_id: machine.id,
      timestamp: DateTime.utc_now(),
      cpu: %{
        usage_percent: :rand.uniform() * 50 + 10,
        user_percent: :rand.uniform() * 30,
        system_percent: :rand.uniform() * 20,
        cores: 2,
        load_average: [:rand.uniform() * 2, :rand.uniform() * 2, :rand.uniform() * 2],
        throttled: false
      },
      memory: %{
        rss_bytes: 1024 * 1024 * 256,
        vsz_bytes: 1024 * 1024 * 512,
        swap_bytes: 0,
        page_faults: 1024,
        cgroup_limit_bytes: 1024 * 1024 * Map.get(machine.metadata, "memory_mb", 512),
        oom_score: 100
      },
      io: %{
        read_bytes: 1024 * 1024 * 100,
        write_bytes: 1024 * 1024 * 50,
        read_ops: 1000,
        write_ops: 500
      },
      threads: %{
        count: 8,
        running: 1,
        sleeping: 6,
        blocked: 1
      },
      network: %{
        connections: 12,
        established: 8,
        listening: 4
      },
      file_descriptors: %{
        open: 64,
        limit_soft: 1024,
        limit_hard: 4096
      }
    }
  end

  defp fetch_machine_threads(machine, include_stacks) do
    base_threads = [
      %{
        tid: 1,
        name: "main",
        state: "S",
        cpu_percent: 2.5,
        stack_trace: ["main+0x123", "start_thread+0x456", "clone+0x789"]
      },
      %{
        tid: 2,
        name: "worker-1",
        state: "R",
        cpu_percent: 12.3,
        stack_trace: ["process_request+0xabc", "handle_connection+0xdef"]
      },
      %{
        tid: 3,
        name: "worker-2",
        state: "S",
        cpu_percent: 0.5,
        stack_trace: ["epoll_wait+0x111", "event_loop+0x222"]
      },
      %{
        tid: 4,
        name: "gc",
        state: "S",
        cpu_percent: 0.1,
        stack_trace: ["futex_wait+0x333", "pthread_cond_wait+0x444"]
      }
    ]

    if include_stacks do
      base_threads
    else
      Enum.map(base_threads, fn thread -> Map.delete(thread, :stack_trace) end)
    end
  end

  defp fetch_machine_connections(machine, listening_only, protocol_filter) do
    all_connections = [
      %{
        protocol: "tcp",
        local_addr: "0.0.0.0",
        local_port: 8080,
        remote_addr: "0.0.0.0",
        remote_port: 0,
        state: "LISTEN"
      },
      %{
        protocol: "tcp",
        local_addr: "192.168.1.10",
        local_port: 8080,
        remote_addr: "192.168.1.100",
        remote_port: 54321,
        state: "ESTABLISHED"
      },
      %{
        protocol: "tcp",
        local_addr: "192.168.1.10",
        local_port: 8080,
        remote_addr: "192.168.1.101",
        remote_port: 54322,
        state: "ESTABLISHED"
      },
      %{
        protocol: "udp",
        local_addr: "0.0.0.0",
        local_port: 5353,
        remote_addr: "0.0.0.0",
        remote_port: 0,
        state: "LISTEN"
      }
    ]

    all_connections
    |> maybe_filter_listening(listening_only)
    |> maybe_filter_protocol(protocol_filter)
  end

  defp maybe_filter_listening(connections, false), do: connections

  defp maybe_filter_listening(connections, true) do
    Enum.filter(connections, fn conn -> conn.state == "LISTEN" end)
  end

  defp maybe_filter_protocol(connections, nil), do: connections
  defp maybe_filter_protocol(connections, ""), do: connections

  defp maybe_filter_protocol(connections, protocol) do
    Enum.filter(connections, fn conn ->
      String.downcase(conn.protocol) == String.downcase(protocol)
    end)
  end

  defp fetch_machine_file_descriptors(machine, type_filter) do
    all_fds = [
      %{fd: 0, type: "file", target: "/dev/stdin"},
      %{fd: 1, type: "file", target: "/dev/stdout"},
      %{fd: 2, type: "file", target: "/dev/stderr"},
      %{fd: 3, type: "socket", target: "TCP 0.0.0.0:8080"},
      %{fd: 4, type: "socket", target: "TCP 192.168.1.10:8080->192.168.1.100:54321"},
      %{fd: 5, type: "file", target: "/var/log/app.log"},
      %{fd: 6, type: "pipe", target: "[pipe:12345]"},
      %{fd: 7, type: "file", target: "/app/config.toml"},
      %{fd: 8, type: "socket", target: "UNIX /tmp/app.sock"}
    ]

    case type_filter do
      nil -> all_fds
      "" -> all_fds
      type -> Enum.filter(all_fds, fn fd -> fd.type == type end)
    end
  end
end
