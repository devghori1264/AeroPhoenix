defmodule Orchestrator.MachineActor.Supervisor do
  use DynamicSupervisor
  require Logger

  @registry Orchestrator.MachineActorRegistry

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 500,
      max_seconds: 60
    )
  end

  @spec start_machine(keyword()) :: DynamicSupervisor.on_start_child()
  def start_machine(opts) do
    id = Keyword.fetch!(opts, :id)

    case find_machine(id) do
      {:ok, _pid} ->
        {:error, :already_exists}

      {:error, :not_found} ->
        size = Keyword.get(opts, :size, %{})

        resources = %{
          cpu_cores: Map.get(size, :cpu_count) || Map.get(size, "cpu_count") || 1.0,
          memory_mb: Map.get(size, :memory_mb) || Map.get(size, "memory_mb") || 1024,
          disk_mb: Map.get(size, :disk_mb) || Map.get(size, "disk_mb") || 5120
        }

        case Orchestrator.ResourceManager.reserve_resources(id, resources) do
          {:ok, _} ->
            restart_strategy = Keyword.get(opts, :restart, :permanent)

            child_spec =
              Supervisor.child_spec({Orchestrator.MachineActor, opts}, restart: restart_strategy)

            case DynamicSupervisor.start_child(__MODULE__, child_spec) do
              {:ok, pid} ->
                Logger.info("Machine actor started with resources",
                  id: id,
                  pid: inspect(pid),
                  cpu_cores: resources.cpu_cores,
                  memory_mb: resources.memory_mb,
                  disk_mb: resources.disk_mb
                )

                :telemetry.execute(
                  [:machine_actor_supervisor, :machine_started],
                  %{count: 1},
                  %{id: id, cpu_cores: resources.cpu_cores, memory_mb: resources.memory_mb}
                )

                {:ok, pid}

              {:error, reason} ->
                Orchestrator.ResourceManager.release_resources(id)

                Logger.info("Failed to start machine actor, resources released",
                  id: id,
                  reason: inspect(reason)
                )

                {:error, reason}
            end

          {:error, capacity_error, shortfall} ->
            queue_opts = Keyword.get(opts, :queue_on_exhaustion, false)

            if queue_opts do
              priority = Keyword.get(opts, :priority, 50)
              metadata = extract_metadata(opts)

              case Orchestrator.ResourceQueue.enqueue(
                     id,
                     resources,
                     priority: priority,
                     metadata: metadata
                   ) do
                {:ok, ticket_id} ->
                  Logger.info("Machine queued due to insufficient resources",
                    id: id,
                    ticket_id: ticket_id,
                    error: capacity_error,
                    priority: priority
                  )

                  :telemetry.execute(
                    [:machine_actor_supervisor, :queued],
                    %{count: 1},
                    %{error: capacity_error, machine_id: id, priority: priority}
                  )

                  {:queued, ticket_id}

                {:error, :queue_full} ->
                  Logger.error("Queue full, cannot start machine",
                    id: id,
                    error: capacity_error
                  )

                  {:error, :queue_full}
              end
            else
              Logger.info("Cannot start machine: insufficient resources",
                id: id,
                error: capacity_error,
                shortfall: inspect(shortfall)
              )

              :telemetry.execute(
                [:machine_actor_supervisor, :insufficient_resources],
                %{count: 1},
                %{error: capacity_error, machine_id: id}
              )

              {:error, capacity_error, shortfall}
            end
        end
    end
  end

  @spec find_machine(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def find_machine(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @spec stop_machine(String.t()) :: :ok
  def stop_machine(id) do
    case find_machine(id) do
      {:ok, pid} ->
        freed_resources = get_machine_resources(id)

        :ok = DynamicSupervisor.terminate_child(__MODULE__, pid)

        Orchestrator.ResourceManager.release_resources(id)

        if freed_resources do
          Orchestrator.ResourceQueue.notify_capacity_freed(freed_resources)
        end

        Logger.info("Machine actor stopped and resources released",
          id: id,
          pid: inspect(pid),
          freed_cpu: if(freed_resources, do: freed_resources.cpu_cores, else: 0),
          freed_memory: if(freed_resources, do: freed_resources.memory_mb, else: 0)
        )

        :telemetry.execute(
          [:machine_actor_supervisor, :machine_stopped],
          %{count: 1},
          %{id: id}
        )

        :ok

      {:error, :not_found} ->
        # Machine already stopped/gone - treat as success (idempotent)
        :ok
    end
  end

  @spec list_machines() :: [String.t()]
  def list_machines do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @spec count_machines() :: non_neg_integer()
  def count_machines do
    case Process.whereis(__MODULE__) do
      nil -> 0
      _ -> DynamicSupervisor.count_children(__MODULE__).active
    end
  end

  @spec restart_machine(String.t()) :: {:ok, pid()} | {:error, term()}
  def restart_machine(id) do
    data_dir = Application.get_env(:orchestrator, :machine_actor_data_dir, "data/machines")
    db_path = Path.join(data_dir, "#{id}.db")

    if File.exists?(db_path) do
      _ = stop_machine(id)

      case Orchestrator.MachineActor.Storage.init(db_path) do
        {:ok, conn} ->
          case Orchestrator.MachineActor.Storage.load_metadata(conn) do
            {:ok, metadata} ->
              Orchestrator.MachineActor.Storage.close(conn)

              start_machine(
                id: metadata.id,
                region: metadata.region,
                image: metadata.image,
                size: metadata.size,
                capabilities: metadata.capabilities
              )

            {:error, reason} ->
              Orchestrator.MachineActor.Storage.close(conn)
              {:error, {:metadata_load_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:storage_init_failed, reason}}
      end
    else
      {:error, :no_persisted_state}
    end
  end

  @spec shutdown_all() :: non_neg_integer()
  def shutdown_all do
    machine_ids = list_machines()

    Enum.each(machine_ids, fn id ->
      stop_machine(id)
    end)

    length(machine_ids)
  end

  defp extract_metadata(opts) do
    opts
    |> Keyword.take([:region, :image, :capabilities])
    |> Enum.into(%{})
  end

  defp get_machine_resources(machine_id) do
    case Orchestrator.ResourceManager.get_reservation(machine_id) do
      {:ok, reservation} ->
        %{
          cpu_cores: reservation.cpu_cores,
          memory_mb: reservation.memory_mb,
          disk_mb: reservation.disk_mb
        }

      {:error, :not_found} ->
        nil
    end
  end
end
