defmodule Orchestrator.Debugger.ProcessInspector do
  require Logger

  @type metrics :: %{
          cpu: cpu_metrics(),
          memory: memory_metrics(),
          threads: thread_metrics(),
          io: io_metrics(),
          network: network_metrics(),
          file_descriptors: fd_metrics(),
          system: system_metrics(),
          timestamp: DateTime.t()
        }
  @type cpu_metrics :: %{
          usage_percent: float(),
          user_percent: float(),
          system_percent: float(),
          cores: integer(),
          throttled: boolean(),
          load_average: {float(), float(), float()}
        }
  @type memory_metrics :: %{
          rss_bytes: integer(),
          vsz_bytes: integer(),
          swap_bytes: integer(),
          page_faults: integer(),
          peak_rss_bytes: integer(),
          cgroup_limit_bytes: integer() | nil,
          oom_score: integer()
        }
  @type thread_metrics :: %{
          count: integer(),
          running: integer(),
          sleeping: integer(),
          blocked: integer(),
          threads: list(thread_info())
        }
  @type thread_info :: %{
          tid: integer(),
          name: String.t(),
          state: String.t(),
          cpu_percent: float(),
          stack_trace: list(String.t())
        }
  @type io_metrics :: %{
          read_bytes: integer(),
          write_bytes: integer(),
          read_ops: integer(),
          write_ops: integer(),
          disk_iops: float(),
          disk_throughput_mbps: float()
        }
  @type network_metrics :: %{
          connections: integer(),
          listening_ports: list(integer()),
          established: integer(),
          time_wait: integer(),
          bytes_sent: integer(),
          bytes_received: integer(),
          packets_sent: integer(),
          packets_received: integer()
        }
  @type fd_metrics :: %{
          open: integer(),
          limit_soft: integer(),
          limit_hard: integer(),
          types: %{
            files: integer(),
            sockets: integer(),
            pipes: integer(),
            other: integer()
          }
        }
  @type system_metrics :: %{
          uptime_seconds: integer(),
          boot_time: DateTime.t(),
          context_switches: integer(),
          processes: integer(),
          os: String.t(),
          kernel_version: String.t()
        }
  @spec get_metrics(String.t()) :: {:ok, metrics()} | {:error, term()}
  def get_metrics(machine_id) do
    case get_machine_pid(machine_id) do
      {:ok, pid} ->
        collect_all_metrics(machine_id, pid)

      {:error, _reason} = error ->
        error
    end
  end

  @spec get_cpu_metrics(String.t()) :: {:ok, cpu_metrics()} | {:error, term()}
  def get_cpu_metrics(machine_id) do
    case get_machine_pid(machine_id) do
      {:ok, pid} ->
        {:ok, collect_cpu_metrics(machine_id, pid)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec get_memory_metrics(String.t()) :: {:ok, memory_metrics()} | {:error, term()}
  def get_memory_metrics(machine_id) do
    case get_machine_pid(machine_id) do
      {:ok, pid} ->
        {:ok, collect_memory_metrics(machine_id, pid)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec get_thread_info(String.t()) :: {:ok, list(thread_info())} | {:error, term()}
  def get_thread_info(machine_id) do
    case get_machine_pid(machine_id) do
      {:ok, pid} ->
        {:ok, collect_thread_info(machine_id, pid)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec list_file_descriptors(String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_file_descriptors(machine_id) do
    case get_machine_pid(machine_id) do
      {:ok, pid} ->
        {:ok, collect_fd_list(machine_id, pid)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec get_network_connections(String.t()) :: {:ok, list(map())} | {:error, term()}
  def get_network_connections(machine_id) do
    case get_machine_pid(machine_id) do
      {:ok, pid} ->
        {:ok, collect_network_connections(machine_id, pid)}

      {:error, _reason} = error ->
        error
    end
  end

  defp get_machine_pid(machine_id) do
    case Orchestrator.MachineRegistry.get_pid(machine_id) do
      {:ok, pid} when is_integer(pid) ->
        {:ok, pid}

      {:ok, _} ->
        {:error, :invalid_pid}

      :error ->
        {:error, :machine_not_found}
    end
  end

  defp collect_all_metrics(machine_id, pid) do
    metrics = %{
      cpu: collect_cpu_metrics(machine_id, pid),
      memory: collect_memory_metrics(machine_id, pid),
      threads: collect_thread_metrics(machine_id, pid),
      io: collect_io_metrics(machine_id, pid),
      network: collect_network_metrics(machine_id, pid),
      file_descriptors: collect_fd_metrics(machine_id, pid),
      system: collect_system_metrics(),
      timestamp: DateTime.utc_now()
    }

    {:ok, metrics}
  end

  defp collect_cpu_metrics(_machine_id, pid) do
    stat_path = "/proc/#{pid}/stat"

    case File.read(stat_path) do
      {:ok, content} ->
        parse_cpu_stat(content)

      {:error, _} ->
        %{
          usage_percent: 0.0,
          user_percent: 0.0,
          system_percent: 0.0,
          cores: System.schedulers_online(),
          throttled: false,
          load_average: read_load_average()
        }
    end
  end

  defp parse_cpu_stat(stat_content) do
    parts = String.split(stat_content, " ")
    utime = parts |> Enum.at(13, "0") |> String.to_integer()
    stime = parts |> Enum.at(14, "0") |> String.to_integer()
    clock_ticks = 100
    total_time = utime + stime
    uptime = get_process_uptime(parts)

    usage_percent =
      if uptime > 0 do
        total_time / clock_ticks / uptime * 100.0
      else
        0.0
      end

    user_percent =
      if uptime > 0 do
        utime / clock_ticks / uptime * 100.0
      else
        0.0
      end

    system_percent =
      if uptime > 0 do
        stime / clock_ticks / uptime * 100.0
      else
        0.0
      end

    %{
      usage_percent: Float.round(usage_percent, 2),
      user_percent: Float.round(user_percent, 2),
      system_percent: Float.round(system_percent, 2),
      cores: System.schedulers_online(),
      throttled: check_cpu_throttling(),
      load_average: read_load_average()
    }
  end

  defp get_process_uptime(stat_parts) do
    starttime_jiffies = stat_parts |> Enum.at(21, "0") |> String.to_integer()

    case File.read("/proc/uptime") do
      {:ok, content} ->
        [uptime_str | _] = String.split(content, " ")
        uptime_seconds = String.to_float(uptime_str)
        uptime_seconds - starttime_jiffies / 100

      {:error, _} ->
        1.0
    end
  end

  defp check_cpu_throttling do
    case File.read("/sys/fs/cgroup/cpu.stat") do
      {:ok, content} ->
        String.contains?(content, "throttled")

      {:error, _} ->
        false
    end
  end

  defp read_load_average do
    case File.read("/proc/loadavg") do
      {:ok, content} ->
        [one, five, fifteen | _] = String.split(content, " ")

        {
          String.to_float(one),
          String.to_float(five),
          String.to_float(fifteen)
        }

      {:error, _} ->
        {0.0, 0.0, 0.0}
    end
  end

  defp collect_memory_metrics(_machine_id, pid) do
    status_path = "/proc/#{pid}/status"

    case File.read(status_path) do
      {:ok, content} ->
        parse_memory_status(content, pid)

      {:error, _} ->
        %{
          rss_bytes: 0,
          vsz_bytes: 0,
          swap_bytes: 0,
          page_faults: 0,
          peak_rss_bytes: 0,
          cgroup_limit_bytes: nil,
          oom_score: 0
        }
    end
  end

  defp parse_memory_status(content, pid) do
    lines = String.split(content, "\n")
    rss_kb = extract_memory_value(lines, "VmRSS:")
    vsz_kb = extract_memory_value(lines, "VmSize:")
    swap_kb = extract_memory_value(lines, "VmSwap:")
    peak_rss_kb = extract_memory_value(lines, "VmPeak:")
    page_faults = read_page_faults(pid)
    cgroup_limit = read_cgroup_memory_limit()
    oom_score = read_oom_score(pid)

    %{
      rss_bytes: rss_kb * 1024,
      vsz_bytes: vsz_kb * 1024,
      swap_bytes: swap_kb * 1024,
      page_faults: page_faults,
      peak_rss_bytes: peak_rss_kb * 1024,
      cgroup_limit_bytes: cgroup_limit,
      oom_score: oom_score
    }
  end

  defp extract_memory_value(lines, key) do
    lines
    |> Enum.find("", &String.starts_with?(&1, key))
    |> String.split()
    |> Enum.at(1, "0")
    |> String.to_integer()
  end

  defp read_page_faults(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, content} ->
        parts = String.split(content, " ")
        minflt = parts |> Enum.at(9, "0") |> String.to_integer()
        majflt = parts |> Enum.at(11, "0") |> String.to_integer()
        minflt + majflt

      {:error, _} ->
        0
    end
  end

  defp read_cgroup_memory_limit do
    case File.read("/sys/fs/cgroup/memory.max") do
      {:ok, "max\n"} ->
        nil

      {:ok, content} ->
        String.trim(content) |> String.to_integer()

      {:error, _} ->
        nil
    end
  end

  defp read_oom_score(pid) do
    case File.read("/proc/#{pid}/oom_score") do
      {:ok, content} ->
        String.trim(content) |> String.to_integer()

      {:error, _} ->
        0
    end
  end

  defp collect_thread_metrics(_machine_id, pid) do
    threads = collect_thread_info(_machine_id, pid)
    states = Enum.group_by(threads, & &1.state)

    %{
      count: length(threads),
      running: length(Map.get(states, "R", [])),
      sleeping: length(Map.get(states, "S", [])),
      blocked: length(Map.get(states, "D", [])),
      threads: threads
    }
  end

  defp collect_thread_info(_machine_id, pid) do
    task_dir = "/proc/#{pid}/task"

    case File.ls(task_dir) do
      {:ok, tids} ->
        tids
        |> Enum.map(&String.to_integer/1)
        |> Enum.map(&read_thread_info(pid, &1))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp read_thread_info(pid, tid) do
    stat_path = "/proc/#{pid}/task/#{tid}/stat"
    comm_path = "/proc/#{pid}/task/#{tid}/comm"

    with {:ok, stat_content} <- File.read(stat_path),
         {:ok, name} <- File.read(comm_path) do
      parts = String.split(stat_content, " ")
      state = parts |> Enum.at(2, "S")

      %{
        tid: tid,
        name: String.trim(name),
        state: state,
        cpu_percent: 0.0,
        stack_trace: read_stack_trace(pid, tid)
      }
    else
      _ -> nil
    end
  end

  defp read_stack_trace(pid, tid) do
    stack_path = "/proc/#{pid}/task/#{tid}/stack"

    case File.read(stack_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(10)

      {:error, _} ->
        []
    end
  end

  defp collect_io_metrics(_machine_id, pid) do
    io_path = "/proc/#{pid}/io"

    case File.read(io_path) do
      {:ok, content} ->
        parse_io_stats(content)

      {:error, _} ->
        %{
          read_bytes: 0,
          write_bytes: 0,
          read_ops: 0,
          write_ops: 0,
          disk_iops: 0.0,
          disk_throughput_mbps: 0.0
        }
    end
  end

  defp parse_io_stats(content) do
    lines = String.split(content, "\n")
    read_bytes = extract_io_value(lines, "read_bytes:")
    write_bytes = extract_io_value(lines, "write_bytes:")
    read_ops = extract_io_value(lines, "syscr:")
    write_ops = extract_io_value(lines, "syscw:")

    %{
      read_bytes: read_bytes,
      write_bytes: write_bytes,
      read_ops: read_ops,
      write_ops: write_ops,
      disk_iops: 0.0,
      disk_throughput_mbps: 0.0
    }
  end

  defp extract_io_value(lines, key) do
    lines
    |> Enum.find("", &String.starts_with?(&1, key))
    |> String.split()
    |> Enum.at(1, "0")
    |> String.to_integer()
  end

  defp collect_network_metrics(_machine_id, pid) do
    connections = collect_network_connections(_machine_id, pid)
    states = Enum.group_by(connections, & &1.state)

    %{
      connections: length(connections),
      listening_ports:
        Enum.filter(connections, &(&1.state == "LISTEN"))
        |> Enum.map(& &1.local_port)
        |> Enum.uniq(),
      established: length(Map.get(states, "ESTABLISHED", [])),
      time_wait: length(Map.get(states, "TIME_WAIT", [])),
      bytes_sent: 0,
      bytes_received: 0,
      packets_sent: 0,
      packets_received: 0
    }
  end

  defp collect_network_connections(_machine_id, pid) do
    tcp_connections = parse_tcp_connections("/proc/net/tcp", pid)
    tcp6_connections = parse_tcp_connections("/proc/net/tcp6", pid)
    tcp_connections ++ tcp6_connections
  end

  defp parse_tcp_connections(path, target_pid) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.drop(1)
        |> Enum.map(&parse_tcp_line(&1, target_pid))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp parse_tcp_line(line, target_pid) do
    parts = String.split(line) |> Enum.reject(&(&1 == ""))

    if length(parts) >= 10 do
      inode = parts |> Enum.at(9) |> String.to_integer()

      if connection_belongs_to_process?(target_pid, inode) do
        [local_addr, local_port] = parse_address(Enum.at(parts, 1))
        [remote_addr, remote_port] = parse_address(Enum.at(parts, 2))
        state = parse_tcp_state(Enum.at(parts, 3))

        %{
          local_addr: local_addr,
          local_port: local_port,
          remote_addr: remote_addr,
          remote_port: remote_port,
          state: state,
          inode: inode
        }
      end
    end
  end

  defp connection_belongs_to_process?(pid, inode) do
    fd_dir = "/proc/#{pid}/fd"

    case File.ls(fd_dir) do
      {:ok, fds} ->
        Enum.any?(fds, fn fd ->
          link_path = "#{fd_dir}/#{fd}"

          case File.read_link(link_path) do
            {:ok, target} ->
              String.contains?(target, "[#{inode}]")

            {:error, _} ->
              false
          end
        end)

      {:error, _} ->
        false
    end
  end

  defp parse_address(hex_addr) do
    [addr_hex, port_hex] = String.split(hex_addr, ":")
    port = String.to_integer(port_hex, 16)

    addr =
      addr_hex
      |> String.graphemes()
      |> Enum.chunk_every(2)
      |> Enum.map(&Enum.join/1)
      |> Enum.reverse()
      |> Enum.map(&String.to_integer(&1, 16))
      |> Enum.join(".")

    [addr, port]
  end

  defp parse_tcp_state("01"), do: "ESTABLISHED"
  defp parse_tcp_state("02"), do: "SYN_SENT"
  defp parse_tcp_state("03"), do: "SYN_RECV"
  defp parse_tcp_state("04"), do: "FIN_WAIT1"
  defp parse_tcp_state("05"), do: "FIN_WAIT2"
  defp parse_tcp_state("06"), do: "TIME_WAIT"
  defp parse_tcp_state("07"), do: "CLOSE"
  defp parse_tcp_state("08"), do: "CLOSE_WAIT"
  defp parse_tcp_state("09"), do: "LAST_ACK"
  defp parse_tcp_state("0A"), do: "LISTEN"
  defp parse_tcp_state("0B"), do: "CLOSING"
  defp parse_tcp_state(_), do: "UNKNOWN"

  defp collect_fd_metrics(_machine_id, pid) do
    fd_list = collect_fd_list(_machine_id, pid)
    types = categorize_fds(fd_list)
    limits = read_fd_limits(pid)

    %{
      open: length(fd_list),
      limit_soft: limits.soft,
      limit_hard: limits.hard,
      types: types
    }
  end

  defp collect_fd_list(_machine_id, pid) do
    fd_dir = "/proc/#{pid}/fd"

    case File.ls(fd_dir) do
      {:ok, fds} ->
        fds
        |> Enum.map(&read_fd_info(pid, &1))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp read_fd_info(pid, fd) do
    link_path = "/proc/#{pid}/fd/#{fd}"

    case File.read_link(link_path) do
      {:ok, target} ->
        %{
          fd: String.to_integer(fd),
          target: target,
          type: classify_fd_type(target)
        }

      {:error, _} ->
        nil
    end
  end

  defp classify_fd_type("socket:" <> _), do: :socket
  defp classify_fd_type("pipe:" <> _), do: :pipe
  defp classify_fd_type("/dev/" <> _), do: :device

  defp classify_fd_type(path) do
    if String.starts_with?(path, "/"), do: :file, else: :other
  end

  defp categorize_fds(fd_list) do
    types = Enum.group_by(fd_list, & &1.type)

    %{
      files: length(Map.get(types, :file, [])),
      sockets: length(Map.get(types, :socket, [])),
      pipes: length(Map.get(types, :pipe, [])),
      other: length(Map.get(types, :other, []))
    }
  end

  defp read_fd_limits(pid) do
    case File.read("/proc/#{pid}/limits") do
      {:ok, content} ->
        lines = String.split(content, "\n")
        fd_line = Enum.find(lines, "", &String.starts_with?(&1, "Max open files"))

        if fd_line != "" do
          parts = String.split(fd_line) |> Enum.reject(&(&1 == ""))
          soft = parts |> Enum.at(-2, "1024") |> parse_limit()
          hard = parts |> Enum.at(-1, "4096") |> parse_limit()
          %{soft: soft, hard: hard}
        else
          %{soft: 1024, hard: 4096}
        end

      {:error, _} ->
        %{soft: 1024, hard: 4096}
    end
  end

  defp parse_limit("unlimited"), do: :unlimited
  defp parse_limit(value), do: String.to_integer(value)

  defp collect_system_metrics do
    %{
      uptime_seconds: read_uptime(),
      boot_time: read_boot_time(),
      context_switches: read_context_switches(),
      processes: count_processes(),
      os: "Linux",
      kernel_version: read_kernel_version()
    }
  end

  defp read_uptime do
    case File.read("/proc/uptime") do
      {:ok, content} ->
        [uptime_str | _] = String.split(content, " ")
        String.to_float(uptime_str) |> trunc()

      {:error, _} ->
        0
    end
  end

  defp read_boot_time do
    uptime_seconds = read_uptime()
    DateTime.add(DateTime.utc_now(), -uptime_seconds, :second)
  end

  defp read_context_switches do
    case File.read("/proc/stat") do
      {:ok, content} ->
        lines = String.split(content, "\n")
        ctxt_line = Enum.find(lines, "", &String.starts_with?(&1, "ctxt"))

        if ctxt_line != "" do
          [_, count_str] = String.split(ctxt_line, " ")
          String.to_integer(count_str)
        else
          0
        end

      {:error, _} ->
        0
    end
  end

  defp count_processes do
    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.match?(&1, ~r/^\d+$/))
        |> length()

      {:error, _} ->
        0
    end
  end

  defp read_kernel_version do
    case File.read("/proc/version") do
      {:ok, content} ->
        String.trim(content)

      {:error, _} ->
        "Unknown"
    end
  end
end
