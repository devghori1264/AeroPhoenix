defmodule Orchestrator.Logs.Producer do
  use GenServer
  require Logger

  @log_rates %{
    low: 1,
    normal: 5,
    high: 10,
    burst: 50
  }

  @level_distribution %{
    debug: 0.50,
    info: 0.35,
    warn: 0.10,
    error: 0.05
  }

  @components [
    :init,
    :fsm,
    :network,
    :storage,
    :migration,
    :http_server,
    :database,
    :cache,
    :worker,
    :health_check
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def emit_boot_sequence(pid) do
    GenServer.cast(pid, :emit_boot_sequence)
  end

  def start_runtime_logs(pid) do
    GenServer.cast(pid, :start_runtime_logs)
  end

  def stop_runtime_logs(pid) do
    GenServer.cast(pid, :stop_runtime_logs)
  end

  def emit_error(pid, error_type, context \\ %{}) do
    GenServer.cast(pid, {:emit_error, error_type, context})
  end

  def emit_state_transition(pid, from_state, to_state, context \\ %{}) do
    GenServer.cast(pid, {:emit_state_transition, from_state, to_state, context})
  end

  def set_log_rate(pid, rate) when rate in [:low, :normal, :high, :burst] do
    GenServer.cast(pid, {:set_log_rate, rate})
  end

  @impl true
  def init(opts) do
    machine_id = Keyword.fetch!(opts, :machine_id)
    region = Keyword.fetch!(opts, :region)
    log_rate = Keyword.get(opts, :log_rate, :normal)
    enable_boot = Keyword.get(opts, :enable_boot_sequence, true)
    enable_runtime = Keyword.get(opts, :enable_runtime_logs, true)

    state = %{
      machine_id: machine_id,
      region: region,
      log_rate: log_rate,
      runtime_enabled: enable_runtime and not enable_boot,
      enable_runtime_after_boot: enable_runtime and enable_boot,
      boot_phase: :not_started,
      log_count: 0,
      start_time: System.system_time(:microsecond)
    }

    if enable_boot do
      send(self(), :begin_boot_sequence)
    end

    if enable_runtime and not enable_boot do
      send(self(), :schedule_runtime_log)
    end

    {:ok, state}
  end

  @impl true
  def handle_cast(:emit_boot_sequence, state) do
    send(self(), :begin_boot_sequence)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:start_runtime_logs, state) do
    if not state.runtime_enabled do
      send(self(), :schedule_runtime_log)
      {:noreply, %{state | runtime_enabled: true}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:stop_runtime_logs, state) do
    {:noreply, %{state | runtime_enabled: false}}
  end

  @impl true
  def handle_cast({:emit_error, error_type, context}, state) do
    log = build_error_log(error_type, context, state)
    publish_log(log, state)

    {:noreply, increment_log_count(state)}
  end

  @impl true
  def handle_cast({:emit_state_transition, from_state, to_state, context}, state) do
    log = %{
      timestamp: System.system_time(:microsecond),
      level: :info,
      component: :fsm,
      message: "State transition: #{from_state} → #{to_state}",
      metadata:
        Map.merge(base_metadata(state), %{
          from_state: from_state,
          to_state: to_state,
          transition_duration_ms: Map.get(context, :duration_ms, 0)
        })
    }

    publish_log(log, state)

    {:noreply, increment_log_count(state)}
  end

  @impl true
  def handle_cast({:set_log_rate, rate}, state) do
    {:noreply, %{state | log_rate: rate}}
  end

  @impl true
  def handle_info(:begin_boot_sequence, state) do
    emit_log(:info, :init, "Starting machine initialization", %{}, state)

    Process.send_after(self(), {:boot_phase, :kernel_init}, 100)

    {:noreply, %{state | boot_phase: :starting}}
  end

  @impl true
  def handle_info({:boot_phase, :kernel_init}, state) do
    emit_log(:info, :init, "Kernel initialized", %{version: "5.15.0"}, state)
    emit_log(:debug, :init, "Loading kernel modules", %{modules: ["overlay", "iptables"]}, state)

    Process.send_after(self(), {:boot_phase, :filesystem}, 200)

    {:noreply, %{state | boot_phase: :kernel_init}}
  end

  @impl true
  def handle_info({:boot_phase, :filesystem}, state) do
    emit_log(:info, :storage, "Mounting filesystems", %{}, state)
    emit_log(:debug, :storage, "Mounted /dev/vda at /", %{size_gb: 25}, state)
    emit_log(:debug, :storage, "Mounted tmpfs at /tmp", %{size_mb: 512}, state)

    Process.send_after(self(), {:boot_phase, :network}, 300)

    {:noreply, %{state | boot_phase: :filesystem}}
  end

  @impl true
  def handle_info({:boot_phase, :network}, state) do
    emit_log(:info, :network, "Configuring network interfaces", %{}, state)
    emit_log(:debug, :network, "Interface eth0 up", %{ip: "fdaa:0:1da6::3", mtu: 1500}, state)
    emit_log(:debug, :network, "DNS servers configured", %{servers: ["fdaa::3"]}, state)
    emit_log(:info, :network, "Network ready", %{}, state)

    Process.send_after(self(), {:boot_phase, :services}, 400)

    {:noreply, %{state | boot_phase: :network}}
  end

  @impl true
  def handle_info({:boot_phase, :services}, state) do
    emit_log(:info, :http_server, "Starting HTTP server", %{port: 8080}, state)
    emit_log(:info, :database, "Connecting to database", %{}, state)
    emit_log(:debug, :database, "Database connection established", %{pool_size: 10}, state)
    emit_log(:info, :worker, "Starting background workers", %{count: 4}, state)

    Process.send_after(self(), {:boot_phase, :health_check}, 500)

    {:noreply, %{state | boot_phase: :services}}
  end

  @impl true
  def handle_info({:boot_phase, :health_check}, state) do
    emit_log(:info, :health_check, "Registering health checks", %{}, state)
    emit_log(:debug, :health_check, "Liveness probe: /health/live", %{interval_sec: 10}, state)
    emit_log(:debug, :health_check, "Readiness probe: /health/ready", %{interval_sec: 5}, state)

    Process.send_after(self(), {:boot_phase, :complete}, 200)

    {:noreply, %{state | boot_phase: :health_check}}
  end

  @impl true
  def handle_info({:boot_phase, :complete}, state) do
    boot_duration = (System.system_time(:microsecond) - state.start_time) / 1_000

    emit_log(:info, :init, "Machine ready", %{boot_duration_ms: trunc(boot_duration)}, state)

    new_state = %{state | boot_phase: :complete}

    if Map.get(state, :enable_runtime_after_boot, false) do
      send(self(), :schedule_runtime_log)
      {:noreply, %{new_state | runtime_enabled: true}}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:schedule_runtime_log, state) do
    if state.runtime_enabled do
      log = generate_runtime_log(state)
      publish_log(log, state)

      interval = calculate_log_interval(state.log_rate)
      Process.send_after(self(), :schedule_runtime_log, interval)

      {:noreply, increment_log_count(state)}
    else
      {:noreply, state}
    end
  end

  defp generate_runtime_log(state) do
    level = select_log_level()
    component = Enum.random(@components)
    {message, metadata} = generate_log_content(component, level)

    %{
      timestamp: System.system_time(:microsecond),
      level: level,
      component: component,
      message: message,
      metadata: Map.merge(base_metadata(state), metadata)
    }
  end

  defp generate_log_content(:http_server, level) do
    status_code =
      if level == :error,
        do: Enum.random([500, 502, 503]),
        else: Enum.random([200, 201, 204, 304])

    method = Enum.random(["GET", "POST", "PUT", "DELETE"])
    path = Enum.random(["/api/users", "/api/machines", "/health", "/metrics"])
    duration_ms = :rand.uniform(500)

    {
      "#{method} #{path} #{status_code}",
      %{method: method, path: path, status: status_code, duration_ms: duration_ms}
    }
  end

  defp generate_log_content(:database, level) do
    if level == :error do
      {"Query timeout", %{query: "SELECT * FROM machines", timeout_ms: 5000}}
    else
      query_time = :rand.uniform(50)

      {"Query executed",
       %{
         query: "SELECT * FROM machines WHERE region = $1",
         duration_ms: query_time,
         rows: :rand.uniform(100)
       }}
    end
  end

  defp generate_log_content(:cache, level) do
    if level == :error do
      {"Cache miss", %{key: "machine:mach_123", fallback: :database}}
    else
      hit = Enum.random([true, false])

      {if(hit, do: "Cache hit", else: "Cache miss"),
       %{key: "machine:mach_#{:rand.uniform(1000)}", hit: hit}}
    end
  end

  defp generate_log_content(:worker, level) do
    job_type = Enum.random(["email_send", "report_generation", "cleanup"])

    if level == :error do
      {"Job failed", %{job_type: job_type, attempt: 3, error: "Connection refused"}}
    else
      {"Job completed", %{job_type: job_type, duration_ms: :rand.uniform(5000)}}
    end
  end

  defp generate_log_content(:network, level) do
    if level == :error do
      {"Connection timeout", %{host: "api.external.com", timeout_ms: 10_000}}
    else
      {"Connection established",
       %{host: "api.external.com", tls_version: "1.3", duration_ms: :rand.uniform(200)}}
    end
  end

  defp generate_log_content(:health_check, _level) do
    status = Enum.random(["healthy", "degraded"])
    {"Health check", %{status: status, checks: %{database: "ok", cache: "ok", disk: status}}}
  end

  defp generate_log_content(component, _level) do
    {"#{component} operation", %{operation: "generic", duration_ms: :rand.uniform(100)}}
  end

  defp build_error_log(:oom_killed, context, state) do
    %{
      timestamp: System.system_time(:microsecond),
      level: :error,
      component: :init,
      message: "Process killed: Out of memory",
      metadata:
        Map.merge(
          base_metadata(state),
          Map.merge(
            %{
              memory_usage_mb: 512,
              memory_limit_mb: 512,
              exit_code: 137
            },
            context
          )
        )
    }
  end

  defp build_error_log(:disk_full, context, state) do
    %{
      timestamp: System.system_time(:microsecond),
      level: :error,
      component: :storage,
      message: "Disk space exhausted",
      metadata:
        Map.merge(
          base_metadata(state),
          Map.merge(
            %{
              disk_usage_percent: 100,
              available_mb: 0
            },
            context
          )
        )
    }
  end

  defp build_error_log(:connection_timeout, context, state) do
    %{
      timestamp: System.system_time(:microsecond),
      level: :error,
      component: :network,
      message: "Connection timeout",
      metadata:
        Map.merge(
          base_metadata(state),
          Map.merge(
            %{
              host: "unknown",
              timeout_ms: 30_000
            },
            context
          )
        )
    }
  end

  defp build_error_log(:circuit_breaker_open, context, state) do
    %{
      timestamp: System.system_time(:microsecond),
      level: :warn,
      component: :network,
      message: "Circuit breaker opened",
      metadata:
        Map.merge(
          base_metadata(state),
          Map.merge(
            %{
              service: "external_api",
              failure_threshold: 5,
              failure_count: 5
            },
            context
          )
        )
    }
  end

  defp build_error_log(:health_check_failed, context, state) do
    %{
      timestamp: System.system_time(:microsecond),
      level: :error,
      component: :health_check,
      message: "Health check failed",
      metadata:
        Map.merge(
          base_metadata(state),
          Map.merge(
            %{
              check: "readiness",
              reason: "database unreachable"
            },
            context
          )
        )
    }
  end

  defp build_error_log(:migration_failed, context, state) do
    %{
      timestamp: System.system_time(:microsecond),
      level: :error,
      component: :migration,
      message: "Migration failed",
      metadata:
        Map.merge(
          base_metadata(state),
          Map.merge(
            %{
              phase: "cutover",
              reason: "network partition"
            },
            context
          )
        )
    }
  end

  defp emit_log(level, component, message, metadata, state) do
    log = %{
      timestamp: System.system_time(:microsecond),
      level: level,
      component: component,
      message: message,
      metadata: Map.merge(base_metadata(state), metadata)
    }

    publish_log(log, state)
  end

  defp publish_log(log, state) do
    Phoenix.PubSub.broadcast(
      Orchestrator.PubSub,
      "machine_logs:#{state.machine_id}",
      {:log_event, log}
    )

    Phoenix.PubSub.broadcast(
      Orchestrator.PubSub,
      "log_aggregator:all_machines",
      {:log_event, log}
    )

    :telemetry.execute(
      [:orchestrator, :logs, :produced],
      %{count: 1},
      %{machine_id: state.machine_id, level: log.level, component: log.component}
    )
  end

  defp base_metadata(state) do
    %{
      machine_id: state.machine_id,
      region: state.region,
      node: Node.self()
    }
  end

  defp select_log_level do
    rand = :rand.uniform()

    cond do
      rand < @level_distribution.debug ->
        :debug

      rand < @level_distribution.debug + @level_distribution.info ->
        :info

      rand < @level_distribution.debug + @level_distribution.info + @level_distribution.warn ->
        :warn

      true ->
        :error
    end
  end

  defp calculate_log_interval(rate) do
    logs_per_second = Map.fetch!(@log_rates, rate)
    trunc(1000 / logs_per_second)
  end

  defp increment_log_count(state) do
    %{state | log_count: state.log_count + 1}
  end
end
