defmodule Orchestrator.ResourceQueue do
  use GenServer
  require Logger

  @high_priority_max 33
  @normal_priority_max 66
  @default_priority 50

  @max_queue_age_ms 120_000
  @default_overcommit_ratio %{cpu: 1.2, memory: 1.0, disk: 0.9}
  @backoff_schedule [1000, 2000, 4000, 8000, 16_000, 32_000, 32_000]

  def get_backoff(attempt) do
    Enum.at(@backoff_schedule, attempt, List.last(@backoff_schedule))
  end

  defmodule QueuedRequest do
    @enforce_keys [:id, :machine_id, :resources, :priority, :queued_at, :from, :retry_count]
    defstruct [
      :id,
      :machine_id,
      :resources,
      :priority,
      :queued_at,
      :from,
      :retry_count,
      :last_attempt_at,
      :preemptable,
      metadata: %{}
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def enqueue(machine_id, resources, opts \\ []) do
    GenServer.call(__MODULE__, {:enqueue, machine_id, resources, opts}, 10_000)
  end

  def cancel(ticket_id) do
    GenServer.call(__MODULE__, {:cancel, ticket_id})
  end

  def get_status(ticket_id) do
    GenServer.call(__MODULE__, {:get_status, ticket_id})
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  def notify_capacity_freed(freed_resources) do
    GenServer.cast(__MODULE__, {:capacity_freed, freed_resources})
  end

  def process_queue do
    GenServer.cast(__MODULE__, :process_queue)
  end

  @impl true
  def init(opts) do
    queue_table = :ets.new(:resource_queue, [:set, :protected])

    state = %{
      queue_table: queue_table,
      queue: [],
      config: %{
        max_queue_size: Keyword.get(opts, :max_queue_size, 1000),
        enable_preemption: Keyword.get(opts, :enable_preemption, true),
        overcommit_ratio: Keyword.get(opts, :overcommit_ratio, @default_overcommit_ratio),
        queue_timeout_ms: Keyword.get(opts, :queue_timeout_ms, @max_queue_age_ms)
      },
      stats: %{
        total_enqueued: 0,
        total_dequeued: 0,
        total_timeouts: 0,
        total_preemptions: 0,
        timeouts_1h: [],
        preemptions_1h: []
      }
    }

    schedule_queue_processing(5000)

    schedule_timeout_cleanup(10_000)

    Logger.info("ResourceQueue initialized",
      max_queue_size: state.config.max_queue_size,
      enable_preemption: state.config.enable_preemption,
      overcommit_cpu: state.config.overcommit_ratio.cpu
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, machine_id, resources, opts}, from, state) do
    if length(state.queue) >= state.config.max_queue_size do
      Logger.warning("Queue full, rejecting request",
        machine_id: machine_id,
        queue_size: length(state.queue)
      )

      {:reply, {:error, :queue_full}, state}
    else
      ticket_id = generate_ticket_id()
      priority = Keyword.get(opts, :priority, @default_priority)
      preemptable = Keyword.get(opts, :preemptable, true)
      metadata = Keyword.get(opts, :metadata, %{})

      request = %QueuedRequest{
        id: ticket_id,
        machine_id: machine_id,
        resources: resources,
        priority: priority,
        queued_at: System.monotonic_time(:millisecond),
        from: from,
        retry_count: 0,
        last_attempt_at: nil,
        preemptable: preemptable,
        metadata: metadata
      }

      :ets.insert(state.queue_table, {ticket_id, request})

      new_queue = insert_into_queue(state.queue, request)

      new_stats = %{state.stats | total_enqueued: state.stats.total_enqueued + 1}

      new_state = %{state | queue: new_queue, stats: new_stats}

      :telemetry.execute(
        [:orchestrator, :resource_queue, :enqueue],
        %{count: 1, queue_size: length(new_queue)},
        %{
          priority: priority,
          cpu_cores: resources.cpu_cores,
          memory_mb: resources.memory_mb
        }
      )

      Logger.info("Request queued",
        ticket_id: ticket_id,
        machine_id: machine_id,
        priority: priority,
        position: Enum.find_index(new_queue, fn r -> r.id == ticket_id end) + 1,
        queue_size: length(new_queue)
      )

      send(self(), :attempt_dequeue)

      {:reply, {:ok, ticket_id}, new_state}
    end
  end

  @impl true
  def handle_call({:cancel, ticket_id}, _from, state) do
    case :ets.lookup(state.queue_table, ticket_id) do
      [{^ticket_id, request}] ->
        new_queue = Enum.reject(state.queue, fn r -> r.id == ticket_id end)
        :ets.delete(state.queue_table, ticket_id)

        Logger.info("Request cancelled",
          ticket_id: ticket_id,
          machine_id: request.machine_id
        )

        {:reply, :ok, %{state | queue: new_queue}}

      [] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get_status, ticket_id}, _from, state) do
    case :ets.lookup(state.queue_table, ticket_id) do
      [{^ticket_id, request}] ->
        position = Enum.find_index(state.queue, fn r -> r.id == ticket_id end)
        wait_time_ms = System.monotonic_time(:millisecond) - request.queued_at

        {:reply, {:queued, position + 1, wait_time_ms}, state}

      [] ->
        {:reply, {:not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = build_queue_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:capacity_freed, freed_resources}, state) do
    Logger.debug("Capacity freed, attempting dequeue",
      cpu_cores: freed_resources.cpu_cores,
      memory_mb: freed_resources.memory_mb
    )

    :telemetry.execute(
      [:orchestrator, :resource_queue, :capacity_freed],
      %{
        cpu_cores: freed_resources.cpu_cores,
        memory_mb: freed_resources.memory_mb
      },
      %{}
    )

    send(self(), :attempt_dequeue)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:process_queue, state) do
    send(self(), :attempt_dequeue)
    {:noreply, state}
  end

  @impl true
  def handle_info(:attempt_dequeue, state) do
    new_state = attempt_dequeue_pending(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:periodic_processing, state) do
    new_state = attempt_dequeue_pending(state)
    schedule_queue_processing(5000)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:timeout_cleanup, state) do
    new_state = cleanup_timeouts(state)
    schedule_timeout_cleanup(10_000)
    {:noreply, new_state}
  end

  defp insert_into_queue(queue, request) do
    insert_sorted(queue, request)
  end

  defp insert_sorted([], request), do: [request]

  defp insert_sorted([head | tail] = queue, request) do
    cond do
      request.priority < head.priority ->
        [request | queue]

      request.priority == head.priority and request.queued_at < head.queued_at ->
        [request | queue]

      true ->
        [head | insert_sorted(tail, request)]
    end
  end

  defp attempt_dequeue_pending(state) do
    if Enum.empty?(state.queue) do
      state
    else
      capacity = Orchestrator.ResourceManager.get_capacity()
      adjusted_capacity = apply_overcommit(capacity, state.config.overcommit_ratio)

      {dequeued, remaining, new_stats} =
        process_queue_with_capacity(
          state.queue,
          adjusted_capacity,
          state.stats,
          state.queue_table
        )

      Enum.each(dequeued, fn request ->
        start_machine_from_queue(request)
      end)

      %{state | queue: remaining, stats: new_stats}
    end
  end

  defp process_queue_with_capacity(queue, capacity, stats, queue_table) do
    Enum.reduce(queue, {[], [], stats}, fn request, {dequeued, remaining, acc_stats} ->
      available = capacity.available

      can_fit? =
        available.cpu_cores >= request.resources.cpu_cores and
          available.memory_mb >= request.resources.memory_mb and
          available.disk_mb >= request.resources.disk_mb

      if can_fit? do
        :ets.delete(queue_table, request.id)

        new_available = %{
          cpu_cores: available.cpu_cores - request.resources.cpu_cores,
          memory_mb: available.memory_mb - request.resources.memory_mb,
          disk_mb: available.disk_mb - request.resources.disk_mb
        }

        _new_capacity = %{capacity | available: new_available}

        new_stats = %{acc_stats | total_dequeued: acc_stats.total_dequeued + 1}

        Logger.info("Request dequeued",
          ticket_id: request.id,
          machine_id: request.machine_id,
          wait_time_ms: System.monotonic_time(:millisecond) - request.queued_at
        )

        :telemetry.execute(
          [:orchestrator, :resource_queue, :dequeue],
          %{
            wait_time_ms: System.monotonic_time(:millisecond) - request.queued_at,
            retry_count: request.retry_count
          },
          %{priority: request.priority}
        )

        {[request | dequeued], remaining, new_stats}
      else
        {dequeued, [request | remaining], acc_stats}
      end
    end)
    |> then(fn {dequeued, remaining, stats} ->
      {Enum.reverse(dequeued), Enum.reverse(remaining), stats}
    end)
  end

  defp apply_overcommit(capacity, overcommit_ratio) do
    total = capacity.total
    reserved = capacity.reserved

    adjusted_total = %{
      cpu_cores: total.cpu_cores * overcommit_ratio.cpu,
      memory_mb: trunc(total.memory_mb * overcommit_ratio.memory),
      disk_mb: trunc(total.disk_mb * overcommit_ratio.disk)
    }

    available = %{
      cpu_cores: max(0.0, adjusted_total.cpu_cores - reserved.cpu_cores),
      memory_mb: max(0, adjusted_total.memory_mb - reserved.memory_mb),
      disk_mb: max(0, adjusted_total.disk_mb - reserved.disk_mb)
    }

    %{capacity | total: adjusted_total, available: available}
  end

  defp start_machine_from_queue(request) do
    opts =
      [
        id: request.machine_id,
        size: %{
          cpu_count: request.resources.cpu_cores,
          memory_mb: request.resources.memory_mb,
          disk_mb: request.resources.disk_mb
        }
      ]
      |> Keyword.merge(Map.to_list(request.metadata))

    result = Orchestrator.MachineActor.Supervisor.start_machine(opts)

    GenServer.reply(request.from, result)
  end

  defp cleanup_timeouts(state) do
    now = System.monotonic_time(:millisecond)
    max_age = state.config.queue_timeout_ms

    {timedout, remaining} =
      Enum.split_with(state.queue, fn request ->
        age = now - request.queued_at
        age > max_age
      end)

    Enum.each(timedout, fn request ->
      :ets.delete(state.queue_table, request.id)

      GenServer.reply(request.from, {:error, :queue_timeout})

      Logger.warning("Request timed out in queue",
        ticket_id: request.id,
        machine_id: request.machine_id,
        age_ms: now - request.queued_at
      )

      :telemetry.execute(
        [:orchestrator, :resource_queue, :timeout],
        %{age_ms: now - request.queued_at},
        %{priority: request.priority}
      )
    end)

    timeout_count = length(timedout)

    new_stats = %{
      state.stats
      | total_timeouts: state.stats.total_timeouts + timeout_count,
        timeouts_1h: [now | state.stats.timeouts_1h] |> Enum.take(timeout_count)
    }

    %{state | queue: remaining, stats: new_stats}
  end

  defp build_queue_stats(state) do
    {high, normal, low} =
      Enum.reduce(state.queue, {0, 0, 0}, fn request, {h, n, l} ->
        cond do
          request.priority <= @high_priority_max -> {h + 1, n, l}
          request.priority <= @normal_priority_max -> {h, n + 1, l}
          true -> {h, n, l + 1}
        end
      end)

    now = System.monotonic_time(:millisecond)
    hour_ago = now - 3_600_000

    avg_wait =
      if Enum.empty?(state.queue) do
        0
      else
        total_wait = Enum.reduce(state.queue, 0, fn r, acc -> acc + (now - r.queued_at) end)
        div(total_wait, length(state.queue))
      end

    oldest_age =
      case state.queue do
        [] -> 0
        [oldest | _] -> now - oldest.queued_at
      end

    preemptions_1h = Enum.count(state.stats.preemptions_1h, fn ts -> ts > hour_ago end)
    timeouts_1h = Enum.count(state.stats.timeouts_1h, fn ts -> ts > hour_ago end)

    %{
      total_queued: length(state.queue),
      high_priority: high,
      normal_priority: normal,
      low_priority: low,
      avg_wait_ms: avg_wait,
      oldest_age_ms: oldest_age,
      preemptions_1h: preemptions_1h,
      timeouts_1h: timeouts_1h,
      total_enqueued: state.stats.total_enqueued,
      total_dequeued: state.stats.total_dequeued,
      total_timeouts: state.stats.total_timeouts
    }
  end

  defp schedule_queue_processing(delay_ms) do
    Process.send_after(self(), :periodic_processing, delay_ms)
  end

  defp schedule_timeout_cleanup(delay_ms) do
    Process.send_after(self(), :timeout_cleanup, delay_ms)
  end

  defp generate_ticket_id do
    "ticket-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end
end
