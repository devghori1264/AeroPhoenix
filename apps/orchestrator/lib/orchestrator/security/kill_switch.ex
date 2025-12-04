defmodule Orchestrator.Security.KillSwitch do
  use GenServer
  require Logger

  @type machine_id :: String.t()
  @type metric :: atom()
  @type reason :: String.t() | {atom(), any()}
  @type kill_scope :: :machine | :region | :cluster | :customer
  @cpu_threshold_percent 95.0
  @memory_threshold_percent 95.0
  @network_threshold_mbps 125.0
  @api_rate_threshold_rps 1000
  @consecutive_violations_to_trip 5

  @monitoring_interval_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_monitoring(machine_id(), keyword()) :: :ok
  def start_monitoring(machine_id, opts \\ []) do
    GenServer.call(__MODULE__, {:start_monitoring, machine_id, opts})
  end

  @spec stop_monitoring(machine_id()) :: :ok
  def stop_monitoring(machine_id) do
    GenServer.call(__MODULE__, {:stop_monitoring, machine_id})
  end

  @spec report_metric(machine_id(), metric(), number()) :: :ok
  def report_metric(machine_id, metric, value) do
    GenServer.cast(__MODULE__, {:report_metric, machine_id, metric, value})
  end

  @spec check_health(machine_id()) :: :healthy | {:warning, any()} | {:killed, any()}
  def check_health(machine_id) do
    GenServer.call(__MODULE__, {:check_health, machine_id})
  end

  @spec kill_machine(machine_id(), keyword()) :: :ok
  def kill_machine(machine_id, opts \\ []) do
    GenServer.call(__MODULE__, {:kill_machine, machine_id, opts}, :infinity)
  end

  @spec global_kill(keyword()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def global_kill(opts) do
    GenServer.call(__MODULE__, {:global_kill, opts}, :infinity)
  end

  @spec get_audit_log(keyword()) :: [map()]
  def get_audit_log(filters \\ []) do
    GenServer.call(__MODULE__, {:get_audit_log, filters})
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def init(_opts) do
    :ets.new(:kill_switch_state, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:resource_baseline, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:kill_switch_audit, [:named_table, :ordered_set, :public, read_concurrency: true])

    state = %{
      monitoring_pids: %{},
      total_kills: 0,
      kills_by_reason: %{}
    }

    Logger.info("Kill Switch started")

    :telemetry.execute(
      [:orchestrator, :kill_switch, :started],
      %{},
      %{}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:start_monitoring, machine_id, opts}, _from, state) do
    simulate = Keyword.get(opts, :simulate, true)

    monitor_pid =
      if simulate do
        spawn_link(fn -> monitoring_loop(machine_id) end)
      else
        nil
      end

    :ets.insert(:kill_switch_state, {machine_id, :closed, 0, []})

    Logger.info("Started monitoring machine=#{machine_id} simulate=#{simulate}")

    :telemetry.execute(
      [:orchestrator, :kill_switch, :monitoring_started],
      %{},
      %{machine_id: machine_id}
    )

    new_state =
      if monitor_pid do
        put_in(state.monitoring_pids[machine_id], monitor_pid)
      else
        put_in(state.monitoring_pids[machine_id], :no_pid)
      end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:stop_monitoring, machine_id}, _from, state) do
    case Map.get(state.monitoring_pids, machine_id) do
      nil -> :ok
      :no_pid -> :ok
      pid -> Process.exit(pid, :normal)
    end

    :ets.delete(:kill_switch_state, machine_id)

    Logger.info("Stopped monitoring machine=#{machine_id}")

    new_state = Map.update!(state, :monitoring_pids, &Map.delete(&1, machine_id))
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:check_health, machine_id}, _from, state) do
    result =
      case :ets.lookup(:kill_switch_state, machine_id) do
        [] ->
          :healthy

        [{^machine_id, :closed, _violations, []}] ->
          :healthy

        [{^machine_id, :closed, violations, warnings}]
        when violations < @consecutive_violations_to_trip ->
          {:warning, warnings}

        [{^machine_id, :open, _violations, reasons}] ->
          {:killed, reasons}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:kill_machine, machine_id, opts}, _from, state) do
    reason = Keyword.get(opts, :reason, "Manual kill")

    do_kill_machine(machine_id, reason)

    :ets.insert(:kill_switch_state, {machine_id, :open, 0, [reason]})

    log_audit_event(machine_id, :killed, %{reason: reason, manual: true})

    Logger.warning("Killed machine=#{machine_id} reason=#{inspect(reason)}")

    :telemetry.execute(
      [:orchestrator, :kill_switch, :machine_killed],
      %{},
      %{machine_id: machine_id, reason: reason, manual: true}
    )

    new_state =
      state
      |> Map.update!(:total_kills, &(&1 + 1))
      |> Map.update!(:kills_by_reason, fn reasons ->
        Map.update(reasons, :manual, 1, &(&1 + 1))
      end)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:global_kill, opts}, _from, state) do
    scope = Keyword.fetch!(opts, :scope)
    reason = Keyword.fetch!(opts, :reason)
    authorized_by = Keyword.get(opts, :authorized_by, [])

    if length(authorized_by) < 2 do
      {:reply, {:error, :insufficient_authorization}, state}
    else
      machines_to_kill =
        case scope do
          :region ->
            region = Keyword.fetch!(opts, :region)
            find_machines_in_region(region)

          :cluster ->
            find_all_machines()

          :customer ->
            customer_id = Keyword.fetch!(opts, :customer_id)
            find_machines_for_customer(customer_id)
        end

      Enum.each(machines_to_kill, fn machine_id ->
        do_kill_machine(machine_id, reason)
        :ets.insert(:kill_switch_state, {machine_id, :open, 0, [reason]})

        log_audit_event(machine_id, :global_killed, %{
          reason: reason,
          scope: scope,
          authorized_by: authorized_by
        })
      end)

      killed_count = length(machines_to_kill)

      Logger.error(
        "GLOBAL KILL: scope=#{scope} reason=#{reason} killed=#{killed_count} authorized_by=#{inspect(authorized_by)}"
      )

      :telemetry.execute(
        [:orchestrator, :kill_switch, :global_kill],
        %{killed_count: killed_count},
        %{scope: scope, reason: reason, authorized_by: authorized_by}
      )

      new_state =
        state
        |> Map.update!(:total_kills, &(&1 + killed_count))
        |> Map.update!(:kills_by_reason, fn reasons ->
          Map.update(reasons, :global, killed_count, &(&1 + killed_count))
        end)

      {:reply, {:ok, killed_count}, new_state}
    end
  end

  @impl true
  def handle_call({:get_audit_log, filters}, _from, state) do
    machine_id = Keyword.get(filters, :machine_id)

    events =
      :ets.tab2list(:kill_switch_audit)
      |> Enum.map(fn {{timestamp, mid}, event} ->
        Map.put(event, :timestamp, timestamp) |> Map.put(:machine_id, mid)
      end)
      |> then(fn events ->
        if machine_id do
          Enum.filter(events, fn event -> event.machine_id == machine_id end)
        else
          events
        end
      end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    {:reply, events, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    active_warnings =
      :ets.tab2list(:kill_switch_state)
      |> Enum.count(fn {_mid, status, _violations, warnings} ->
        status == :closed and length(warnings) > 0
      end)

    stats = %{
      total_kills: state.total_kills,
      kills_by_reason: state.kills_by_reason,
      active_warnings: active_warnings,
      monitored_machines: map_size(state.monitoring_pids)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:report_metric, machine_id, metric, value}, state) do
    violation = check_threshold(metric, value)

    if violation do
      [{^machine_id, status, violations, warnings}] = :ets.lookup(:kill_switch_state, machine_id)

      new_violations = violations + 1
      new_warnings = [violation | warnings] |> Enum.take(5)

      if new_violations >= @consecutive_violations_to_trip and status == :closed do
        do_kill_machine(machine_id, {:circuit_breaker_tripped, violation})
        :ets.insert(:kill_switch_state, {machine_id, :open, new_violations, new_warnings})

        log_audit_event(machine_id, :circuit_breaker_tripped, %{
          violation: violation,
          consecutive_violations: new_violations
        })

        Logger.error(
          "Circuit breaker TRIPPED: machine=#{machine_id} violation=#{inspect(violation)} consecutive=#{new_violations}"
        )

        :telemetry.execute(
          [:orchestrator, :kill_switch, :circuit_breaker_tripped],
          %{consecutive_violations: new_violations},
          %{machine_id: machine_id, violation: violation}
        )

        new_state =
          state
          |> Map.update!(:total_kills, &(&1 + 1))
          |> Map.update!(:kills_by_reason, fn reasons ->
            Map.update(reasons, violation, 1, &(&1 + 1))
          end)

        {:noreply, new_state}
      else
        :ets.insert(:kill_switch_state, {machine_id, status, new_violations, new_warnings})

        if new_violations == 1 do
          log_audit_event(machine_id, :warning, %{
            metric: metric,
            value: value,
            violation: violation
          })

          Logger.warning(
            "Threshold violation: machine=#{machine_id} metric=#{metric} value=#{value}"
          )

          :telemetry.execute(
            [:orchestrator, :kill_switch, :threshold_violation],
            %{value: value},
            %{machine_id: machine_id, metric: metric}
          )
        end

        {:noreply, state}
      end
    else
      case :ets.lookup(:kill_switch_state, machine_id) do
        [{^machine_id, :closed, violations, _warnings}] when violations > 0 ->
          :ets.insert(:kill_switch_state, {machine_id, :closed, 0, []})
          Logger.debug("Violations reset: machine=#{machine_id}")

        _ ->
          :ok
      end

      {:noreply, state}
    end
  end

  defp monitoring_loop(machine_id) do
    cpu = :rand.uniform(100)
    memory = :rand.uniform(100)
    network = :rand.uniform(150)

    GenServer.cast(__MODULE__, {:report_metric, machine_id, :cpu_percent, cpu})
    GenServer.cast(__MODULE__, {:report_metric, machine_id, :memory_percent, memory})
    GenServer.cast(__MODULE__, {:report_metric, machine_id, :network_mbps, network})

    Process.sleep(@monitoring_interval_ms)
    monitoring_loop(machine_id)
  end

  defp check_threshold(:cpu_percent, value) when value > @cpu_threshold_percent, do: :cpu_exceeded

  defp check_threshold(:memory_percent, value) when value > @memory_threshold_percent,
    do: :memory_exceeded

  defp check_threshold(:network_mbps, value) when value > @network_threshold_mbps,
    do: :network_flood

  defp check_threshold(:api_rate_rps, value) when value > @api_rate_threshold_rps, do: :api_abuse
  defp check_threshold(_metric, _value), do: nil

  defp do_kill_machine(machine_id, _reason) do
    graceful_timeout =
      Application.get_env(:orchestrator, :kill_switch, [])
      |> Keyword.get(:graceful_shutdown_timeout, 10_000)

    force_timeout =
      Application.get_env(:orchestrator, :kill_switch, [])
      |> Keyword.get(:force_kill_timeout, 1_000)

    Logger.info(
      "Sending SIGTERM to machine=#{machine_id} graceful=#{graceful_timeout} force=#{force_timeout}"
    )

    Process.sleep(graceful_timeout)
    still_running = :rand.uniform(10) > 8

    if still_running do
      Logger.warning("Machine #{machine_id} did not respond to SIGTERM, sending SIGKILL")

      Process.sleep(force_timeout)
    end

    Logger.info("Cleaned up resources for machine=#{machine_id}")

    :ok
  end

  defp log_audit_event(machine_id, action, metadata) do
    timestamp = DateTime.utc_now()
    event = Map.merge(%{action: action}, metadata)
    :ets.insert(:kill_switch_audit, {{timestamp, machine_id}, event})
  end

  defp find_machines_in_region(_region) do
    ["machine_1", "machine_2", "machine_3"]
  end

  defp find_all_machines do
    ["machine_1", "machine_2", "machine_3", "machine_4"]
  end

  defp find_machines_for_customer(_customer_id) do
    ["machine_1", "machine_2"]
  end
end
