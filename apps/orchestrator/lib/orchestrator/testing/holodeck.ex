defmodule Orchestrator.Testing.Holodeck do
  use GenServer
  require Logger

  @type machine_id :: String.t()
  @type scenario :: :ramp_up | :spike | :sustained | :chaos
  @type metrics :: map()

  @default_ramp_interval_ms 30_000
  @default_sustained_duration_ms 3_600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec spawn_machines(pos_integer()) :: {:ok, [machine_id()]} | {:error, term()}
  def spawn_machines(count) do
    GenServer.call(__MODULE__, {:spawn_machines, count}, :infinity)
  end

  @spec run_scenario(scenario(), keyword()) :: :ok
  def run_scenario(scenario, opts \\ []) do
    GenServer.cast(__MODULE__, {:run_scenario, scenario, opts})
  end

  @spec measure_throughput(fun(), keyword()) :: {:ok, float()}
  def measure_throughput(operation, opts \\ []) do
    GenServer.call(__MODULE__, {:measure_throughput, operation, opts}, :infinity)
  end

  @spec measure_latency(fun(), keyword()) :: {:ok, map()}
  def measure_latency(operation, opts \\ []) do
    GenServer.call(__MODULE__, {:measure_latency, operation, opts}, :infinity)
  end

  @spec report_metrics() :: metrics()
  def report_metrics do
    GenServer.call(__MODULE__, :report_metrics)
  end

  @spec stop_all_machines() :: :ok
  def stop_all_machines do
    GenServer.call(__MODULE__, :stop_all_machines, :infinity)
  end

  @spec list_machines() :: [machine_id()]
  def list_machines do
    GenServer.call(__MODULE__, :list_machines)
  end

  @impl true
  def init(_opts) do
    :ets.new(:holodeck_machines, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:holodeck_metrics, [:named_table, :set, :public])
    :ets.new(:holodeck_failures, [:named_table, :bag, :public])

    state = %{
      total_spawned: 0,
      spawn_latencies: [],
      failed_operations: 0
    }

    Logger.debug("Holodeck Load Generator started")

    :telemetry.execute(
      [:orchestrator, :holodeck, :started],
      %{},
      %{}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:spawn_machines, count}, _from, state) do
    Logger.debug("Holodeck: Spawning #{count} machines...")

    start_time = System.monotonic_time(:microsecond)

    machine_ids =
      if count > 0 do
        1..count
        |> Task.async_stream(
          fn i ->
            spawn_single_machine("holodeck_machine_#{i}_#{:rand.uniform(1_000_000)}")
          end,
          max_concurrency: 1000,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, machine_id} -> machine_id end)
      else
        []
      end

    end_time = System.monotonic_time(:microsecond)
    duration_sec = if count > 0, do: (end_time - start_time) / 1_000_000, else: 0.0
    throughput = if count > 0 and duration_sec > 0, do: count / duration_sec, else: 0.0

    Logger.debug(
      "Holodeck: Spawned #{count} machines in #{Float.round(duration_sec, 2)}s (#{Float.round(throughput, 1)} machines/sec)"
    )

    :telemetry.execute(
      [:orchestrator, :holodeck, :machines_spawned],
      %{count: count, duration_ms: div(end_time - start_time, 1000), throughput: throughput},
      %{}
    )

    new_state = %{
      state
      | total_spawned: state.total_spawned + count
    }

    {:reply, {:ok, machine_ids}, new_state}
  end

  @impl true
  def handle_call({:measure_throughput, operation, opts}, _from, state) do
    iterations = Keyword.get(opts, :iterations, 1000)

    start_time = System.monotonic_time(:microsecond)

    if iterations > 0 do
      for _ <- 1..iterations do
        operation.()
      end
    end

    end_time = System.monotonic_time(:microsecond)
    duration_sec = (end_time - start_time) / 1_000_000

    throughput =
      if duration_sec > 0 do
        iterations / duration_sec
      else
        0.0
      end

    {:reply, {:ok, throughput}, state}
  end

  @impl true
  def handle_call({:measure_latency, operation, opts}, _from, state) do
    iterations = Keyword.get(opts, :iterations, 1000)

    latencies =
      for _ <- 1..iterations do
        start_time = System.monotonic_time(:microsecond)
        operation.()
        end_time = System.monotonic_time(:microsecond)
        end_time - start_time
      end

    sorted_latencies = Enum.sort(latencies)

    percentiles = %{
      p50: percentile(sorted_latencies, 50),
      p95: percentile(sorted_latencies, 95),
      p99: percentile(sorted_latencies, 99),
      p999: percentile(sorted_latencies, 99.9)
    }

    {:reply, {:ok, percentiles}, state}
  end

  @impl true
  def handle_call(:report_metrics, _from, state) do
    memory_bytes = :erlang.memory(:total)
    memory_mb = div(memory_bytes, 1_024 * 1_024)

    process_count = :erlang.system_info(:process_count)

    case :erlang.statistics(:scheduler_wall_time) do
      {:scheduler_wall_time_all, samples} -> samples
      samples when is_list(samples) -> samples
      _ -> []
    end
    |> Enum.map(fn
      {_type, _id, active, total} -> active / max(total, 1)
      {_id, util} -> util
    end)
    |> Enum.sum()

    scheduler_usage =
      case :erlang.statistics(:scheduler_wall_time) do
        {:scheduler_wall_time_all, samples} -> samples
        samples when is_list(samples) -> samples
        _ -> []
      end
      |> Enum.map(fn
        {_type, _id, active, total} -> active / max(total, 1)
        {_id, util} -> util
      end)
      |> Enum.sum()
      |> Kernel./(System.schedulers_online())

    ets_memory_bytes =
      :ets.all()
      |> Enum.map(fn table -> :ets.info(table, :memory) * :erlang.system_info(:wordsize) end)
      |> Enum.sum()

    ets_memory_mb = div(ets_memory_bytes, 1_024 * 1_024)

    machine_count = :ets.info(:holodeck_machines, :size)

    metrics = %{
      total_spawned: state.total_spawned,
      active_machines: machine_count,
      memory_mb: memory_mb,
      ets_memory_mb: ets_memory_mb,
      process_count: process_count,
      scheduler_utilization: Float.round(scheduler_usage, 2),
      failed_operations: state.failed_operations
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:stop_all_machines, _from, state) do
    Logger.debug("Holodeck: Stopping all machines...")

    machines = :ets.tab2list(:holodeck_machines)

    Enum.each(machines, fn {machine_id, pid} ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      :ets.delete(:holodeck_machines, machine_id)
    end)

    Logger.debug("Holodeck: Stopped #{length(machines)} machines")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_machines, _from, state) do
    machines =
      :ets.tab2list(:holodeck_machines)
      |> Enum.map(fn {machine_id, _pid} -> machine_id end)

    {:reply, machines, state}
  end

  @impl true
  def handle_cast({:run_scenario, :ramp_up, opts}, state) do
    target = Keyword.get(opts, :target, 5000)
    interval = Keyword.get(opts, :interval, @default_ramp_interval_ms)

    Logger.debug("Holodeck: Running RAMP-UP scenario (target=#{target}, interval=#{interval}ms)")

    Task.start(fn ->
      run_ramp_up_scenario(target, interval)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:run_scenario, :spike, opts}, state) do
    count = Keyword.get(opts, :count, 5000)

    Logger.debug("Holodeck: Running SPIKE scenario (count=#{count})")

    Task.start(fn ->
      spawn_machines(count)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:run_scenario, :sustained, opts}, state) do
    count = Keyword.get(opts, :count, 5000)
    duration = Keyword.get(opts, :duration, @default_sustained_duration_ms)

    Logger.debug("Holodeck: Running SUSTAINED scenario (count=#{count}, duration=#{duration}ms)")

    Task.start(fn ->
      run_sustained_scenario(count, duration)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:run_scenario, :chaos, opts}, state) do
    count = Keyword.get(opts, :count, 1000)
    failure_rate = Keyword.get(opts, :failure_rate, 10)

    Logger.debug(
      "Holodeck: Running CHAOS scenario (count=#{count}, failure_rate=#{failure_rate}%)"
    )

    Task.start(fn ->
      run_chaos_scenario(count, failure_rate)
    end)

    {:noreply, state}
  end

  defp spawn_single_machine(machine_id) do
    {:ok, pid} =
      Task.start_link(fn ->
        simulated_machine_loop(machine_id)
      end)

    :ets.insert(:holodeck_machines, {machine_id, pid})

    machine_id
  end

  defp simulated_machine_loop(machine_id) do
    receive do
      :stop -> :ok
      _ -> simulated_machine_loop(machine_id)
    after
      60_000 ->
        simulated_machine_loop(machine_id)
    end
  end

  defp run_ramp_up_scenario(target, interval) do
    current = 10

    ramp_up_step(current, target, interval)
  end

  defp ramp_up_step(current, target, _interval) when current > target do
    Logger.debug("Holodeck: Ramp-up complete (reached #{current} machines)")
    :ok
  end

  defp ramp_up_step(current, target, interval) do
    Logger.debug("Holodeck: Ramp-up step: spawning #{current} machines...")

    spawn_machines(current)

    Process.sleep(interval)

    ramp_up_step(current * 2, target, interval)
  end

  defp run_sustained_scenario(count, duration) do
    {:ok, _machines} = spawn_machines(count)

    Logger.debug("Holodeck: Sustained load running for #{div(duration, 1000)}s...")

    end_time = System.monotonic_time(:millisecond) + duration

    sustained_loop(end_time)
  end

  defp sustained_loop(end_time) do
    now = System.monotonic_time(:millisecond)

    if now < end_time do
      if :rand.uniform(100) < 10 do
        spawn_single_machine("sustained_#{:rand.uniform(1_000_000)}")
      end

      Process.sleep(1000)
      sustained_loop(end_time)
    else
      Logger.debug("Holodeck: Sustained load complete")
      :ok
    end
  end

  defp run_chaos_scenario(count, failure_rate) do
    {:ok, machines} = spawn_machines(count)

    machines_to_kill = Enum.take_random(machines, div(count * failure_rate, 100))

    Enum.each(machines_to_kill, fn machine_id ->
      case :ets.lookup(:holodeck_machines, machine_id) do
        [{^machine_id, pid}] ->
          Process.exit(pid, :kill)
          :ets.delete(:holodeck_machines, machine_id)
          Logger.warning("Holodeck: Chaos killed machine #{machine_id}")

        [] ->
          :ok
      end
    end)

    Logger.debug(
      "Holodeck: Chaos scenario complete (killed #{length(machines_to_kill)} machines)"
    )
  end

  defp percentile(sorted_list, p) do
    index = round(length(sorted_list) * p / 100) - 1
    index = max(0, index)
    Enum.at(sorted_list, index, 0)
  end
end
