defmodule Orchestrator.Manager do
  @moduledoc """
  The core GenServer responsible for managing and reconciling machine state.

  - Persists machine state declaratively in the database (Postgres via Ecto).
  - Interacts with the `flyd-sim` service via the `Orchestrator.Client`.
  - Runs a periodic reconciliation loop (`handle_info(:reconcile, ...)`) to:
    - Compare the desired state (DB) with the actual state (`flyd-sim`).
    - Perform self-healing actions (e.g., recreating missing remote machines).
    - Query the `Orchestrator.Predictor` for migration suggestions.
  - Manages the ETS table used by the `Predictor` module.
  """

  use GenServer
  require Logger
  alias Orchestrator.{Repo, Machine, Client, Predictor}
  import Ecto.Query, only: [from: 2]

  # The ETS table name used by the Predictor module.
  @predictor_table :orch_predictor
  # How often the reconciliation loop runs (in milliseconds).
  @reconcile_interval 3_000

  ## ─────────────────────────────
  ## Public API
  ## ─────────────────────────────

  @doc """
  Starts the Manager GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Requests the creation of a new machine.

  Persists the machine record locally first, then asynchronously requests
  creation on the remote `flyd-sim` service. The remote ID is stored
  in the machine's metadata upon successful remote creation.

  Returns `{:ok, %Machine{}}` or `{:error, reason}`.
  """
  def create_machine(name, region) do
    # Use a timeout for the synchronous call to the GenServer.
    GenServer.call(__MODULE__, {:create_machine, name, region}, 10_000)
  end

  @doc """
  Retrieves a machine directly from the database by its ID.
  """
  def get_machine(id), do: Repo.get(Machine, id)

  ## ─────────────────────────────
  ## GenServer Callbacks
  ## ─────────────────────────────

  @impl true
  def init(_state) do
    Logger.info("Starting Orchestrator.Manager...")

    # Create the ETS table for the Predictor if it doesn't exist.
    # This Manager process now owns the table lifecycle.
    @predictor_table
    |> :ets.whereis()
    |> case do
      :undefined ->
        :ets.new(@predictor_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          # Give ownership to this Manager process's heir
          # (ensures table cleanup if manager crashes and isn't restarted)
          heir: Process.whereis(Orchestrator.Supervisor)
        ])
        Logger.info("Predictor ETS table '#{@predictor_table}' created by Manager.")

      _pid ->
        # Should ideally not happen if supervision is correct, but handles restarts.
        Logger.info("Predictor ETS table '#{@predictor_table}' already exists.")
    end

    # Start the periodic reconciliation loop.
    schedule_reconcile()

    # Initial state is an empty map, can be extended later if needed.
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_machine, name, region}, _from, state) do
    Logger.info("Handling create_machine call for name: #{name}, region: #{region}")

    changeset = Machine.changeset(%Machine{}, %{
      name: name,
      region: region,
      status: "pending" # Initial status before remote interaction
    })

    case Repo.insert(changeset) do
      {:ok, machine} ->
        Logger.debug("Machine record inserted locally: #{machine.id}")
        # Successfully created locally, now request remote creation.
        handle_remote_creation(machine, state)

      {:error, changeset} ->
        Logger.error("Failed to insert machine locally: #{inspect(changeset.errors)}")
        {:reply, {:error, changeset}, state}
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    Logger.debug("Running reconciliation loop...")
    # Perform the reconciliation logic.
    reconcile_all()
    # Schedule the next run.
    schedule_reconcile()
    # No state change needed here.
    {:noreply, state}
  end

  ## ─────────────────────────────
  ## Internal Logic: Creation
  ## ─────────────────────────────

  # Handles the call to flyd-sim after local DB insert.
  defp handle_remote_creation(%Machine{} = machine, state) do
    case Client.create_machine(machine.name, machine.region) do
      {:ok, %{"id" => remote_id, "status" => remote_status}} ->
        Logger.info("Remote machine created successfully for local ID #{machine.id}, remote ID: #{remote_id}")
        # Update local record with remote ID and status
        metadata = Map.put(machine.metadata || %{}, "remote_id", remote_id)
        update_changeset = Ecto.Changeset.change(machine, metadata: metadata, status: remote_status)

        case Repo.update(update_changeset) do
          {:ok, updated_machine} ->
            {:reply, {:ok, updated_machine}, state}
          {:error, changeset} ->
            # This is tricky: remote exists, local failed to update. Reconciliation should fix.
            Logger.error("Failed to update local machine #{machine.id} with remote ID: #{inspect(changeset.errors)}")
            {:reply, {:error, :local_update_failed_after_remote_create}, state}
        end

      {:error, reason} ->
        Logger.error("Failed creating remote machine for local ID #{machine.id}: #{inspect(reason)}")
        # Local record exists but remote failed. Reconciliation might retry or flag this.
        # For now, just report the error. Consider updating local status to "error_creating"?
        {:reply, {:error, :remote_create_failed}, state}
    end
  end

  ## ─────────────────────────────
  ## Internal Logic: Reconciliation
  ## ─────────────────────────────

  # Fetches all non-terminated machines and spawns a task for each reconciliation.
  defp reconcile_all do
    query = from m in Machine, where: m.status != "terminated"
    machines = Repo.all(query)
    Logger.debug("Found #{length(machines)} machines to reconcile.")

    # Spawn unsupervised tasks for concurrent reconciliation.
    # Warning: This can lead to thundering herd if many machines exist.
    # Consider using Task.Supervisor.async_stream with max_concurrency in production.
    Enum.each(machines, fn machine ->
      spawn(fn -> reconcile_machine(machine) end)
    end)
  end

  # The core reconciliation logic for a single machine.
  defp reconcile_machine(%Machine{} = machine) do
    Logger.debug("Reconciling machine #{machine.id}...")
    # Use `with` for a clear success path.
    with {:ok, remote_state} <- get_remote_state(machine),
         :ok <- maybe_update_local_status(machine, remote_state),
         :ok <- maybe_suggest_migration(machine) # Pass only machine
    do
      :ok # Successfully reconciled
    else
      # Handle specific error cases from the `with` block.
      {:error, :remote_not_found} ->
        Logger.warning("Remote machine not found for local ID #{machine.id}. Attempting self-heal (recreate)...", machine_id: machine.id)
        handle_self_heal_recreate(machine)

      {:error, reason} ->
        Logger.error("Reconciliation error for machine #{machine.id}: #{inspect(reason)}", machine_id: machine.id)
        :error # Propagate other errors
    end
  end

  # Fetches the current state from the remote flyd-sim service.
  defp get_remote_state(%Machine{metadata: %{"remote_id" => remote_id}}) when not is_nil(remote_id) do
    case Client.get_machine(remote_id) do
      {:ok, %{"id" => _id, "status" => status}} ->
        {:ok, %{"remote_status" => status}}
      {:error, {:http_error, 404}} ->
        {:error, :remote_not_found} # Specific error for 404
      {:error, reason} ->
        # Log other client errors but potentially treat as transient?
        Logger.error("Failed to get remote state for machine #{remote_id}: #{inspect(reason)}")
        {:error, {:remote_fetch_failed, reason}}
    end
  end
  # If remote_id is missing in metadata, we can't fetch remote state.
  defp get_remote_state(%Machine{} = machine) do
    Logger.warning("Cannot get remote state for machine #{machine.id}: missing 'remote_id' in metadata.", machine_id: machine.id)
    # This could happen if initial remote creation failed.
    # Treat as if remote is not found to trigger potential recreate.
    {:error, :remote_not_found}
  end

  # Updates the local DB status if it differs from the remote status.
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
      :ok # Status matches, no update needed.
    end
  end

  # Calls the predictor and updates metadata if a migration is suggested.
  # Renamed from maybe_suggest_migration(m, _remote) as remote state isn't needed here.
  defp maybe_suggest_migration(%Machine{} = machine) do
    case Predictor.should_migrate?(machine.id) do
      {:migrate, reason} ->
        Logger.info("Predictor suggests migration for machine #{machine.id}: #{reason}", machine_id: machine.id)
        # Check if suggestion already exists to avoid redundant updates
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
          :ok # Suggestion already recorded
        end
      :ok ->
         # Optional: Clear previous suggestion if prediction is now :ok
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
           :ok # No suggestion and none currently recorded
         end
    end
  end

  # Attempts to recreate a machine on flyd-sim when it's missing.
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

  # Schedules the next :reconcile message.
  defp schedule_reconcile do
    Process.send_after(self(), :reconcile, @reconcile_interval)
  end
end
