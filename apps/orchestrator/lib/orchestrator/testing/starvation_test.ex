defmodule Orchestrator.Testing.StarvationTest do
  use GenServer
  require Logger

  @type region :: String.t()
  @type machine_id :: String.t()
  @type capacity :: non_neg_integer()

  @default_max_retries 5
  @default_base_delay_ms 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec set_capacity(region(), capacity()) :: :ok
  def set_capacity(region, capacity) do
    GenServer.call(__MODULE__, {:set_capacity, region, capacity})
  end

  @spec fill_to_capacity(region(), capacity()) :: {:ok, [machine_id()]} | {:error, term()}
  def fill_to_capacity(region, target) do
    GenServer.call(__MODULE__, {:fill_to_capacity, region, target}, :infinity)
  end

  @spec test_starvation(region()) :: {:ok, machine_id()} | {:error, :insufficient_capacity}
  def test_starvation(region) do
    GenServer.call(__MODULE__, {:test_starvation, region})
  end

  @spec retry_with_backoff(region(), keyword()) ::
          {:ok, machine_id()} | {:error, :max_retries_exceeded}
  def retry_with_backoff(region, opts \\ []) do
    GenServer.call(__MODULE__, {:retry_with_backoff, region, opts}, :infinity)
  end

  @spec find_available_region([region()]) ::
          {:ok, {machine_id(), region()}} | {:error, :no_available_regions}
  def find_available_region(regions) do
    GenServer.call(__MODULE__, {:find_available_region, regions})
  end

  @spec get_capacity_stats(region()) :: map()
  def get_capacity_stats(region) do
    GenServer.call(__MODULE__, {:get_capacity_stats, region})
  end

  @spec deallocate_machine(machine_id()) :: :ok
  def deallocate_machine(machine_id) do
    GenServer.cast(__MODULE__, {:deallocate_machine, machine_id})
  end

  @spec clear_region(region()) :: :ok
  def clear_region(region) do
    GenServer.call(__MODULE__, {:clear_region, region})
  end

  @impl true
  def init(_opts) do
    :ets.new(:region_capacity, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:machine_allocations, [:named_table, :set, :public])

    Logger.info("Starvation Test: Started")

    {:ok, %{}}
  end

  @impl true
  def handle_call({:set_capacity, region, capacity}, _from, state) do
    :ets.insert(:region_capacity, {region, capacity})

    Logger.info("Starvation Test: Set capacity for #{region} to #{capacity}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:fill_to_capacity, region, target}, _from, state) do
    Logger.info("Starvation Test: Filling #{region} to #{target} machines...")

    machine_ids =
      1..target
      |> Task.async_stream(
        fn i ->
          machine_id = "starvation_test_machine_#{region}_#{i}_#{:rand.uniform(1_000_000)}"
          allocate_machine(machine_id, region)
        end,
        max_concurrency: 100,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, machine_id} -> machine_id end)

    Logger.info("Starvation Test: Filled #{region} with #{length(machine_ids)} machines")

    :telemetry.execute(
      [:orchestrator, :starvation_test, :region_filled],
      %{count: length(machine_ids)},
      %{region: region}
    )

    {:reply, {:ok, machine_ids}, state}
  end

  @impl true
  def handle_call({:test_starvation, region}, _from, state) do
    case check_capacity(region) do
      {:ok, _available} ->
        machine_id = "starvation_test_unexpected_#{:rand.uniform(1_000_000)}"
        allocate_machine(machine_id, region)

        Logger.warning("Starvation Test: #{region} has capacity (expected full)")

        {:reply, {:ok, machine_id}, state}

      {:error, :insufficient_capacity} ->
        Logger.info("Starvation Test: #{region} is full (as expected)")

        :telemetry.execute(
          [:orchestrator, :starvation_test, :capacity_exceeded],
          %{},
          %{region: region}
        )

        {:reply, {:error, :insufficient_capacity}, state}
    end
  end

  @impl true
  def handle_call({:retry_with_backoff, region, opts}, _from, state) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    jitter = Keyword.get(opts, :jitter, true)

    Logger.info("Starvation Test: Retrying #{region} with backoff (max #{max_retries} attempts)")

    result = do_retry_with_backoff(region, 0, max_retries, base_delay_ms, jitter)

    case result do
      {:ok, _machine_id} ->
        Logger.info("Starvation Test: Retry succeeded after backoff")

      {:error, :max_retries_exceeded} ->
        Logger.info("Starvation Test: Max retries (#{max_retries}) exceeded")

        :telemetry.execute(
          [:orchestrator, :starvation_test, :retry_exhausted],
          %{attempts: max_retries},
          %{region: region}
        )
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_available_region, regions}, _from, state) do
    Logger.info("Starvation Test: Trying fallback regions: #{inspect(regions)}")

    result = try_regions(regions)

    case result do
      {:ok, {_machine_id, region}} ->
        Logger.info("Starvation Test: Placed in fallback region #{region}")

        :telemetry.execute(
          [:orchestrator, :starvation_test, :fallback_success],
          %{},
          %{region: region}
        )

      {:error, :no_available_regions} ->
        Logger.warning("Starvation Test: All regions full")

        :telemetry.execute(
          [:orchestrator, :starvation_test, :all_regions_full],
          %{},
          %{}
        )
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_capacity_stats, region}, _from, state) do
    stats = calculate_capacity_stats(region)

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:clear_region, region}, _from, state) do
    pattern = {:"$1", region}
    machines = :ets.match(:machine_allocations, pattern)

    Enum.each(machines, fn [machine_id] ->
      :ets.delete(:machine_allocations, machine_id)
    end)

    Logger.info("Starvation Test: Cleared #{length(machines)} machines from #{region}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:deallocate_machine, machine_id}, state) do
    :ets.delete(:machine_allocations, machine_id)

    Logger.debug("Starvation Test: Deallocated machine #{machine_id}")

    {:noreply, state}
  end

  defp allocate_machine(machine_id, region) do
    :ets.insert(:machine_allocations, {machine_id, region})
    machine_id
  end

  defp check_capacity(region) do
    capacity =
      case :ets.lookup(:region_capacity, region) do
        [{^region, cap}] -> cap
        [] -> :infinity
      end

    used = count_machines_in_region(region)

    if capacity == :infinity or used < capacity do
      available = if capacity == :infinity, do: :infinity, else: capacity - used
      {:ok, available}
    else
      {:error, :insufficient_capacity}
    end
  end

  defp count_machines_in_region(region) do
    pattern = {:"$1", region}
    :ets.match(:machine_allocations, pattern) |> length()
  end

  defp do_retry_with_backoff(_region, attempt, max_retries, _base_delay, _jitter)
       when attempt >= max_retries do
    {:error, :max_retries_exceeded}
  end

  defp do_retry_with_backoff(region, attempt, max_retries, base_delay_ms, jitter) do
    case check_capacity(region) do
      {:ok, _available} ->
        machine_id = "retry_success_#{region}_#{:rand.uniform(1_000_000)}"
        allocate_machine(machine_id, region)
        {:ok, machine_id}

      {:error, :insufficient_capacity} ->
        delay_ms = calculate_delay(attempt, base_delay_ms, jitter)

        Logger.debug("Starvation Test: Retry attempt #{attempt + 1}, waiting #{delay_ms}ms")

        Process.sleep(delay_ms)

        do_retry_with_backoff(region, attempt + 1, max_retries, base_delay_ms, jitter)
    end
  end

  defp calculate_delay(attempt, base_delay_ms, jitter) do
    delay = (base_delay_ms * :math.pow(2, attempt)) |> round()

    if jitter do
      :rand.uniform(delay)
    else
      delay
    end
  end

  defp try_regions([]) do
    {:error, :no_available_regions}
  end

  defp try_regions([region | rest]) do
    case check_capacity(region) do
      {:ok, _available} ->
        machine_id = "fallback_#{region}_#{:rand.uniform(1_000_000)}"
        allocate_machine(machine_id, region)
        {:ok, {machine_id, region}}

      {:error, :insufficient_capacity} ->
        try_regions(rest)
    end
  end

  defp calculate_capacity_stats(region) do
    total =
      case :ets.lookup(:region_capacity, region) do
        [{^region, cap}] -> cap
        [] -> 0
      end

    used = count_machines_in_region(region)
    available = max(0, total - used)
    utilization = if total > 0, do: used / total, else: 0.0

    status =
      cond do
        utilization < 0.7 -> :healthy
        utilization < 0.85 -> :warning
        utilization < 1.0 -> :critical
        true -> :full
      end

    %{
      total: total,
      used: used,
      available: available,
      utilization: Float.round(utilization, 2),
      status: status
    }
  end
end
