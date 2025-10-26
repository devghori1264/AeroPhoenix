defmodule Orchestrator.Manager do

  use GenServer
  require Logger
  alias Orchestrator.{Repo, Machine, Client, Predictor}
  import Ecto.Query, only: [from: 2]

  @predictor_table :orch_predictor
  @reconcile_interval 3_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def create_machine(name, region) do
    GenServer.call(__MODULE__, {:create_machine, name, region}, 10_000)
  end

  def get_machine(id), do: Repo.get(Machine, id)

  def list_machines do
    Repo.all(Machine)
  end

  def topology do
    machines = Repo.all(Machine)

    topology = machines
    |> Enum.group_by(& &1.region)
    |> Enum.map(fn {region, machines} ->
      %{
        region: region,
        machines: Enum.map(machines, fn m ->
          %{
            id: m.id,
            name: m.name,
            status: m.status,
            metadata: m.metadata
          }
        end)
      }
    end)

    %{topology: topology}
  end

  @impl true
  def init(_state) do
    Logger.info("Starting Orchestrator.Manager...")
    @predictor_table
    |> :ets.whereis()
    |> case do
      :undefined ->
        :ets.new(@predictor_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          heir: Process.whereis(Orchestrator.Supervisor)
        ])
        Logger.info("Predictor ETS table '#{@predictor_table}' created by Manager.")
        Logger.info("Predictor ETS table '#{@predictor_table}' already exists.")
    end
    schedule_reconcile()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_machine, name, region}, _from, state) do
    Logger.info("Handling create_machine call for name: #{name}, region: #{region}")

    changeset = Machine.changeset(%Machine{}, %{
      name: name,
      region: region,
      status: "pending"
    })

    case Repo.insert(changeset) do
      {:ok, machine} ->
        Logger.debug("Machine record inserted locally: #{machine.id}")
        handle_remote_creation(machine, state)

      {:error, changeset} ->
        Logger.error("Failed to insert machine locally: #{inspect(changeset.errors)}")
        {:reply, {:error, changeset}, state}
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    Logger.debug("Running reconciliation loop...")
    reconcile_all()
    schedule_reconcile()
    {:noreply, state}
  end

  defp handle_remote_creation(%Machine{} = machine, state) do
    case Client.create_machine(machine.name, machine.region) do
      {:ok, %{"id" => remote_id, "status" => remote_status}} ->
        Logger.info("Remote machine created successfully for local ID #{machine.id}, remote ID: #{remote_id}")
        metadata = Map.put(machine.metadata || %{}, "remote_id", remote_id)
        update_changeset = Ecto.Changeset.change(machine, metadata: metadata, status: remote_status)

        case Repo.update(update_changeset) do
          {:ok, updated_machine} ->
            {:reply, {:ok, updated_machine}, state}
          {:error, changeset} ->
            Logger.error("Failed to update local machine #{machine.id} with remote ID: #{inspect(changeset.errors)}")
            {:reply, {:error, :local_update_failed_after_remote_create}, state}
        end

      {:error, reason} ->
        Logger.error("Failed creating remote machine for local ID #{machine.id}: #{inspect(reason)}")
        {:reply, {:error, :remote_create_failed}, state}
    end
  end

  defp reconcile_all do
    query = from m in Machine, where: m.status != "terminated"
    machines = Repo.all(query)
    Logger.debug("Found #{length(machines)} machines to reconcile.")
    Enum.each(machines, fn machine ->
      spawn(fn -> reconcile_machine(machine) end)
    end)
  end

  defp reconcile_machine(%Machine{} = machine) do
    Logger.debug("Reconciling machine #{machine.id}...")
    with {:ok, remote_state} <- get_remote_state(machine),
         :ok <- maybe_update_local_status(machine, remote_state),
         :ok <- maybe_suggest_migration(machine)
    do
      :ok
    else
      {:error, :remote_not_found} ->
        Logger.warning("Remote machine not found for local ID #{machine.id}. Attempting self-heal (recreate)...", machine_id: machine.id)
        handle_self_heal_recreate(machine)

      {:error, reason} ->
        Logger.error("Reconciliation error for machine #{machine.id}: #{inspect(reason)}", machine_id: machine.id)
        :error
    end
  end

  defp get_remote_state(%Machine{metadata: %{"remote_id" => remote_id}}) when not is_nil(remote_id) do
    case Client.get_machine(remote_id) do
      {:ok, %{"id" => _id, "status" => status}} ->
        {:ok, %{"remote_status" => status}}
      {:error, {:http_error, 404}} ->
        {:error, :remote_not_found}
      {:error, reason} ->
        Logger.error("Failed to get remote state for machine #{remote_id}: #{inspect(reason)}")
        {:error, {:remote_fetch_failed, reason}}
    end
  end
  defp get_remote_state(%Machine{} = machine) do
    Logger.warning("Cannot get remote state for machine #{machine.id}: missing 'remote_id' in metadata.", machine_id: machine.id)
    {:error, :remote_not_found}
  end

  defp maybe_update_local_status(%Machine{} = machine, %{"remote_status" => remote_status}) do
    if machine.status != remote_status do
      Logger.info("Status mismatch for machine #{machine.id}: local=#{machine.status}, remote=#{remote_status}. Updating local.", machine_id: machine.id)
      changeset = Ecto.Changeset.change(machine, status: remote_status)
      case Repo.update(changeset) do
        {:ok, _} -> :ok
        {:error, update_cs} ->
          Logger.error("Failed to update local status for machine #{machine.id}: #{inspect(update_cs.errors)}", machine_id: machine.id)
          {:error, :local_status_update_failed}
      end
    else
      :ok
    end
  end

  defp maybe_suggest_migration(%Machine{} = machine) do
    case Predictor.should_migrate?(machine.id) do
      {:migrate, reason} ->
        Logger.info("Predictor suggests migration for machine #{machine.id}: #{reason}", machine_id: machine.id)
        if get_in(machine.metadata, ["suggestion"]) != reason do
          metadata = Map.put(machine.metadata || %{}, "suggestion", reason)
          changeset = Ecto.Changeset.change(machine, metadata: metadata)
          case Repo.update(changeset) do
            {:ok, _} -> :ok
            {:error, update_cs} ->
              Logger.error("Failed to update machine #{machine.id} metadata with suggestion: #{inspect(update_cs.errors)}", machine_id: machine.id)
              {:error, :local_suggestion_update_failed}
          end
        else
          :ok
        end
      :ok ->
         if Map.has_key?(machine.metadata || %{}, "suggestion") do
           Logger.info("Clearing previous migration suggestion for machine #{machine.id}", machine_id: machine.id)
           metadata = Map.delete(machine.metadata, "suggestion")
           changeset = Ecto.Changeset.change(machine, metadata: metadata)
           case Repo.update(changeset) do
             {:ok, _} -> :ok
             {:error, update_cs} ->
               Logger.error("Failed to clear suggestion for machine #{machine.id}: #{inspect(update_cs.errors)}", machine_id: machine.id)
               {:error, :local_suggestion_clear_failed}
           end
         else
           :ok
         end
    end
  end

  defp handle_self_heal_recreate(%Machine{} = machine) do
    case Client.create_machine(machine.name, machine.region) do
      {:ok, %{"id" => new_remote_id, "status" => new_status}} ->
        Logger.info("Self-heal successful: Recreated remote machine for local ID #{machine.id}, new remote ID: #{new_remote_id}", machine_id: machine.id)
        metadata = Map.put(machine.metadata || %{}, "remote_id", new_remote_id)
        changeset = Ecto.Changeset.change(machine, metadata: metadata, status: new_status)
        case Repo.update(changeset) do
          {:ok, _} -> :ok
          {:error, update_cs} ->
            Logger.error("Self-heal failed: Could not update local record #{machine.id} after recreate: #{inspect(update_cs.errors)}", machine_id: machine.id)
            {:error, :self_heal_local_update_failed}
        end
      {:error, reason} ->
        Logger.error("Self-heal failed: Could not recreate remote machine for local ID #{machine.id}: #{inspect(reason)}", machine_id: machine.id)
        {:error, :self_heal_remote_create_failed}
    end
  end

  defp schedule_reconcile do
    Process.send_after(self(), :reconcile, @reconcile_interval)
  end
end
