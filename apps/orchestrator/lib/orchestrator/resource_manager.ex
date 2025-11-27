defmodule Orchestrator.ResourceManager do
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reserve_resources(machine_id, resources) do
    GenServer.call(__MODULE__, {:reserve, machine_id, resources})
  end

  def release_resources(machine_id) do
    GenServer.call(__MODULE__, {:release, machine_id})
  end

  def can_allocate?(resources) do
    GenServer.call(__MODULE__, {:can_allocate, resources})
  end

  def get_capacity do
    GenServer.call(__MODULE__, :get_capacity)
  end

  def get_reservation(machine_id) do
    GenServer.call(__MODULE__, {:get_reservation, machine_id})
  end

  def list_reservations do
    GenServer.call(__MODULE__, :list_reservations)
  end

  def scan_for_leaks do
    GenServer.call(__MODULE__, :scan_for_leaks, 30_000)
  end

  @impl true
  def init(opts) do
    reservations_table = :ets.new(:resource_reservations, [:set, :protected, :named_table])
    capacity_table = :ets.new(:resource_capacity, [:set, :protected, :named_table])

    total_cpu = Keyword.get(opts, :cpu_cores, 16.0)
    total_memory = Keyword.get(opts, :memory_mb, 65_536)
    total_disk = Keyword.get(opts, :disk_mb, 1_048_576)

    :ets.insert(capacity_table, {:total_cpu, total_cpu})
    :ets.insert(capacity_table, {:total_memory, total_memory})
    :ets.insert(capacity_table, {:total_disk, total_disk})
    :ets.insert(capacity_table, {:reserved_cpu, 0.0})
    :ets.insert(capacity_table, {:reserved_memory, 0})
    :ets.insert(capacity_table, {:reserved_disk, 0})

    state = %{
      reservations_table: reservations_table,
      capacity_table: capacity_table,
      config: %{
        total_cpu: total_cpu,
        total_memory: total_memory,
        total_disk: total_disk,
        leak_scan_interval_ms: Keyword.get(opts, :leak_scan_interval_ms, 60_000),
        enable_overcommit: Keyword.get(opts, :enable_overcommit, false)
      },
      stats: %{
        total_reservations: 0,
        total_releases: 0,
        failed_reservations: 0,
        leaked_reservations: 0
      }
    }

    schedule_leak_scan(state.config.leak_scan_interval_ms)

    Logger.info("ResourceManager initialized",
      cpu_cores: total_cpu,
      memory_mb: total_memory,
      disk_mb: total_disk
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:reserve, machine_id, resources}, _from, state) do
    start_time = System.monotonic_time(:microsecond)

    case :ets.lookup(state.reservations_table, machine_id) do
      [{^machine_id, _existing}] ->
        Logger.debug("Reservation already exists",
          machine_id: machine_id
        )

        duration_us = System.monotonic_time(:microsecond) - start_time
        emit_reservation_telemetry(:success, :idempotent, duration_us, resources)

        {:reply, {:ok, :already_reserved}, state}

      [] ->
        case check_capacity_available(state, resources) do
          {:ok, _available} ->
            reservation = create_reservation(resources)

            :ets.insert(state.reservations_table, {machine_id, reservation})

            update_capacity_reserved(state.capacity_table, resources, :add)

            new_stats = %{
              state.stats
              | total_reservations: state.stats.total_reservations + 1
            }

            duration_us = System.monotonic_time(:microsecond) - start_time

            emit_reservation_telemetry(:success, :new, duration_us, resources)

            Logger.info("Resources reserved",
              machine_id: machine_id,
              cpu_cores: resources.cpu_cores,
              memory_mb: resources.memory_mb,
              disk_mb: resources.disk_mb,
              duration_us: duration_us
            )

            {:reply, {:ok, :reserved}, %{state | stats: new_stats}}

          {:error, reason, shortfall} ->
            new_stats = %{
              state.stats
              | failed_reservations: state.stats.failed_reservations + 1
            }

            duration_us = System.monotonic_time(:microsecond) - start_time

            emit_reservation_telemetry(:failed, reason, duration_us, resources)

            Logger.warning("Reservation failed",
              machine_id: machine_id,
              reason: reason,
              shortfall: shortfall,
              duration_us: duration_us
            )

            {:reply, {:error, reason, shortfall}, %{state | stats: new_stats}}
        end
    end
  end

  @impl true
  def handle_call({:release, machine_id}, _from, state) do
    start_time = System.monotonic_time(:microsecond)

    case :ets.lookup(state.reservations_table, machine_id) do
      [{^machine_id, reservation}] ->
        :ets.delete(state.reservations_table, machine_id)

        resources = %{
          cpu_cores: reservation.cpu_cores,
          memory_mb: reservation.memory_mb,
          disk_mb: reservation.disk_mb
        }

        update_capacity_reserved(state.capacity_table, resources, :subtract)

        new_stats = %{state.stats | total_releases: state.stats.total_releases + 1}

        duration_us = System.monotonic_time(:microsecond) - start_time

        emit_release_telemetry(:success, duration_us, resources)

        Logger.info("Resources released",
          machine_id: machine_id,
          cpu_cores: reservation.cpu_cores,
          memory_mb: reservation.memory_mb,
          disk_mb: reservation.disk_mb,
          duration_us: duration_us
        )

        {:reply, :ok, %{state | stats: new_stats}}

      [] ->
        duration_us = System.monotonic_time(:microsecond) - start_time

        emit_release_telemetry(:success, duration_us, %{
          cpu_cores: 0.0,
          memory_mb: 0,
          disk_mb: 0
        })

        Logger.debug("Release called for non-existent reservation",
          machine_id: machine_id
        )

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:can_allocate, resources}, _from, state) do
    result =
      case check_capacity_available(state, resources) do
        {:ok, _available} -> true
        {:error, _reason, _shortfall} -> false
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_capacity, _from, state) do
    capacity = build_capacity_snapshot(state)
    {:reply, capacity, state}
  end

  @impl true
  def handle_call({:get_reservation, machine_id}, _from, state) do
    result =
      case :ets.lookup(state.reservations_table, machine_id) do
        [{^machine_id, reservation}] -> {:ok, reservation}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_reservations, _from, state) do
    reservations = :ets.tab2list(state.reservations_table)
    {:reply, reservations, state}
  end

  @impl true
  def handle_call(:scan_for_leaks, _from, state) do
    result = execute_leak_scan(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:leak_scan, state) do
    execute_leak_scan(state)

    schedule_leak_scan(state.config.leak_scan_interval_ms)

    {:noreply, state}
  end

  defp check_capacity_available(state, resources) do
    [{:reserved_cpu, reserved_cpu}] = :ets.lookup(state.capacity_table, :reserved_cpu)
    [{:reserved_memory, reserved_memory}] = :ets.lookup(state.capacity_table, :reserved_memory)
    [{:reserved_disk, reserved_disk}] = :ets.lookup(state.capacity_table, :reserved_disk)

    available_cpu = state.config.total_cpu - reserved_cpu
    available_memory = state.config.total_memory - reserved_memory
    available_disk = state.config.total_disk - reserved_disk

    cpu_ok? = resources.cpu_cores <= available_cpu
    memory_ok? = resources.memory_mb <= available_memory
    disk_ok? = resources.disk_mb <= available_disk

    cond do
      not cpu_ok? ->
        shortfall = %{
          requested: resources.cpu_cores,
          available: available_cpu,
          total: state.config.total_cpu
        }

        {:error, :insufficient_cpu, shortfall}

      not memory_ok? ->
        shortfall = %{
          requested: resources.memory_mb,
          available: available_memory,
          total: state.config.total_memory
        }

        {:error, :insufficient_memory, shortfall}

      not disk_ok? ->
        shortfall = %{
          requested: resources.disk_mb,
          available: available_disk,
          total: state.config.total_disk
        }

        {:error, :insufficient_disk, shortfall}

      true ->
        available = %{
          cpu_cores: available_cpu,
          memory_mb: available_memory,
          disk_mb: available_disk
        }

        {:ok, available}
    end
  end

  defp update_capacity_reserved(capacity_table, resources, :add) do
    :ets.update_counter(capacity_table, :reserved_cpu, resources.cpu_cores)
    :ets.update_counter(capacity_table, :reserved_memory, resources.memory_mb)
    :ets.update_counter(capacity_table, :reserved_disk, resources.disk_mb)
  end

  defp update_capacity_reserved(capacity_table, resources, :subtract) do
    :ets.update_counter(capacity_table, :reserved_cpu, -resources.cpu_cores)
    :ets.update_counter(capacity_table, :reserved_memory, -resources.memory_mb)
    :ets.update_counter(capacity_table, :reserved_disk, -resources.disk_mb)
  end

  defp create_reservation(resources) do
    %{
      cpu_cores: resources.cpu_cores,
      memory_mb: resources.memory_mb,
      disk_mb: resources.disk_mb,
      reserved_at: DateTime.utc_now(),
      process_ref: make_ref()
    }
  end

  defp build_capacity_snapshot(state) do
    [{:reserved_cpu, reserved_cpu}] = :ets.lookup(state.capacity_table, :reserved_cpu)
    [{:reserved_memory, reserved_memory}] = :ets.lookup(state.capacity_table, :reserved_memory)
    [{:reserved_disk, reserved_disk}] = :ets.lookup(state.capacity_table, :reserved_disk)

    available_cpu = state.config.total_cpu - reserved_cpu
    available_memory = state.config.total_memory - reserved_memory
    available_disk = state.config.total_disk - reserved_disk

    cpu_util = reserved_cpu / max(state.config.total_cpu, 0.01) * 100.0
    memory_util = reserved_memory / max(state.config.total_memory, 1) * 100.0
    disk_util = reserved_disk / max(state.config.total_disk, 1) * 100.0

    reservations_count = :ets.info(state.reservations_table, :size)

    %{
      total: %{
        cpu_cores: state.config.total_cpu,
        memory_mb: state.config.total_memory,
        disk_mb: state.config.total_disk
      },
      reserved: %{
        cpu_cores: reserved_cpu,
        memory_mb: reserved_memory,
        disk_mb: reserved_disk
      },
      available: %{
        cpu_cores: available_cpu,
        memory_mb: available_memory,
        disk_mb: available_disk
      },
      utilization_pct: %{
        cpu: Float.round(cpu_util, 2),
        memory: Float.round(memory_util, 2),
        disk: Float.round(disk_util, 2)
      },
      reservations_count: reservations_count
    }
  end

  defp execute_leak_scan(state) do
    start_time = System.monotonic_time(:millisecond)

    all_reservations = :ets.tab2list(state.reservations_table)
    scanned_count = length(all_reservations)

    leaked_machines =
      Enum.filter(all_reservations, fn {machine_id, _reservation} ->
        case Registry.lookup(Orchestrator.Registry.Machines, {nil, machine_id}) do
          [{pid, _}] when is_pid(pid) ->
            false

          _ ->
            true
        end
      end)

    Enum.each(leaked_machines, fn {machine_id, reservation} ->
      :ets.delete(state.reservations_table, machine_id)

      resources = %{
        cpu_cores: reservation.cpu_cores,
        memory_mb: reservation.memory_mb,
        disk_mb: reservation.disk_mb
      }

      update_capacity_reserved(state.capacity_table, resources, :subtract)

      Logger.warning("Leaked reservation released",
        machine_id: machine_id,
        age_seconds: DateTime.diff(DateTime.utc_now(), reservation.reserved_at)
      )
    end)

    leaked_count = length(leaked_machines)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:orchestrator, :resource_manager, :leak_scan],
      %{
        scanned: scanned_count,
        released: leaked_count,
        duration_ms: duration_ms
      },
      %{}
    )

    if leaked_count > 0 do
      Logger.info("Leak scan completed",
        scanned: scanned_count,
        released: leaked_count,
        duration_ms: duration_ms
      )
    end

    {:ok, %{scanned: scanned_count, released: leaked_count, duration_ms: duration_ms}}
  end

  defp schedule_leak_scan(interval_ms) do
    Process.send_after(self(), :leak_scan, interval_ms)
  end

  defp emit_reservation_telemetry(status, outcome, duration_us, resources) do
    :telemetry.execute(
      [:orchestrator, :resource_manager, :reserve],
      %{duration_us: duration_us},
      %{
        status: status,
        outcome: outcome,
        cpu_cores: resources.cpu_cores,
        memory_mb: resources.memory_mb,
        disk_mb: resources.disk_mb
      }
    )
  end

  defp emit_release_telemetry(status, duration_us, resources) do
    :telemetry.execute(
      [:orchestrator, :resource_manager, :release],
      %{duration_us: duration_us},
      %{
        status: status,
        cpu_cores: resources.cpu_cores,
        memory_mb: resources.memory_mb,
        disk_mb: resources.disk_mb
      }
    )
  end
end
