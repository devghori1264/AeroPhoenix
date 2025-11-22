defmodule Orchestrator.MachineFSM do
  use GenServer
  require Logger
  alias Orchestrator.{Repo, Machine, FlydClient, MachineEvent}

  @type machine_status ::
          :created
          | :starting
          | :running
          | :stopping
          | :stopped
          | :migrating
          | :restarting
          | :suspended
          | :health_check
          | :destroyed
          | :error
  @type state_transition :: %{
          from: machine_status(),
          to: machine_status(),
          timestamp: DateTime.t(),
          metadata: map(),
          duration_ms: non_neg_integer() | nil
        }
  @type state :: %{
          id: String.t(),
          status: machine_status(),
          previous_status: machine_status() | nil,
          target_region: String.t() | nil,
          retry_count: non_neg_integer(),
          max_retries: non_neg_integer(),
          timer_ref: reference() | nil,
          health_check_ref: reference() | nil,
          state_version: non_neg_integer(),
          state_history: [state_transition()],
          metadata: map(),
          last_transition_at: DateTime.t(),
          crash_count: non_neg_integer(),
          health_check_interval_ms: non_neg_integer(),
          last_health_check_at: DateTime.t() | nil,
          health_check_failures: non_neg_integer(),
          region: String.t() | nil
        }
  @retry_limit 5
  @retry_delay_ms 1000
  @max_retry_delay_ms 32_000
  @health_check_interval_ms 30_000
  @health_check_failure_threshold 3
  @max_state_history 50
  @state_transition_timeout_ms 300_000
  def start_link(%{id: id} = init) when is_binary(id) do
    GenServer.start_link(__MODULE__, init, name: via_tuple(id))
  end

  defp via_tuple(id), do: {:via, Registry, {Orchestrator.FSMRegistry, id}}
  @spec create_or_update(map()) :: {:ok, pid()} | {:error, any()}
  def create_or_update(attrs) do
    id = Map.get(attrs, "id") || Map.get(attrs, :id)
    Orchestrator.MachineManager.ensure_started(id, attrs)
  end

  @doc "Gets current state and status of the machine FSM"
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(machine_id) do
    case Registry.lookup(Orchestrator.FSMRegistry, machine_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get_state)}
      [] -> {:error, :not_found}
    end
  end

  @doc "Gets state transition history for debugging"
  @spec get_history(String.t()) :: {:ok, [state_transition()]} | {:error, :not_found}
  def get_history(machine_id) do
    case Registry.lookup(Orchestrator.FSMRegistry, machine_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get_history)}
      [] -> {:error, :not_found}
    end
  end

  @doc "Forces a health check immediately"
  @spec trigger_health_check(String.t()) :: :ok | {:error, :not_found}
  def trigger_health_check(machine_id) do
    case Registry.lookup(Orchestrator.FSMRegistry, machine_id) do
      [{pid, _}] -> GenServer.cast(pid, :health_check)
      [] -> {:error, :not_found}
    end
  end

  @doc "Suspends a running machine (pause without destroy)"
  @spec suspend(String.t()) :: {:ok, map()} | {:error, term()}
  def suspend(machine_id) do
    case Registry.lookup(Orchestrator.FSMRegistry, machine_id) do
      [{pid, _}] -> GenServer.call(pid, {:command, "suspend"})
      [] -> {:error, :not_found}
    end
  end

  @doc "Resumes a suspended machine"
  @spec resume(String.t()) :: {:ok, map()} | {:error, term()}
  def resume(machine_id) do
    case Registry.lookup(Orchestrator.FSMRegistry, machine_id) do
      [{pid, _}] -> GenServer.call(pid, {:command, "resume"})
      [] -> {:error, :not_found}
    end
  end

  @doc "Destroys a machine permanently"
  @spec destroy(String.t()) :: {:ok, map()} | {:error, term()}
  def destroy(machine_id) do
    case Registry.lookup(Orchestrator.FSMRegistry, machine_id) do
      [{pid, _}] -> GenServer.call(pid, {:command, "destroy"})
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(init) do
    id = to_string(init["id"] || init[:id] || UUID.uuid4())
    machine = Repo.get_by(Machine, id: id)
    initial_status = normalize_status((machine && machine.status) || "created")
    now = DateTime.utc_now()
    region = (machine && machine.region) || init[:region] || init["region"]

    state = %{
      id: id,
      status: initial_status,
      previous_status: nil,
      target_region: nil,
      retry_count: 0,
      max_retries: @retry_limit,
      timer_ref: nil,
      health_check_ref: nil,
      state_version: 0,
      state_history: [],
      metadata: %{},
      last_transition_at: now,
      crash_count: 0,
      health_check_interval_ms: @health_check_interval_ms,
      last_health_check_at: nil,
      health_check_failures: 0,
      region: region
    }

    state =
      if initial_status == :running do
        schedule_health_check(state)
      else
        state
      end

    Logger.info("MachineFSM[#{id}] initialized",
      status: initial_status,
      region: region,
      version: state.state_version
    )

    emit_telemetry(:fsm_initialized, state, %{initial_status: initial_status})
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    response = %{
      id: state.id,
      status: state.status,
      previous_status: state.previous_status,
      region: state.region,
      target_region: state.target_region,
      state_version: state.state_version,
      retry_count: state.retry_count,
      crash_count: state.crash_count,
      health_check_failures: state.health_check_failures,
      last_transition_at: state.last_transition_at,
      last_health_check_at: state.last_health_check_at,
      metadata: state.metadata
    }

    {:reply, response, state}
  end

  def handle_call(:get_history, _from, state) do
    {:reply, state.state_history, state}
  end

  def handle_call({:command, "start"}, _from, state) do
    with :ok <- validate_transition(state.status, :starting) do
      do_start(state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:command, "stop"}, _from, state) do
    with :ok <- validate_transition(state.status, :stopping) do
      do_stop(state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:command, "suspend"}, _from, state) do
    with :ok <- validate_transition(state.status, :suspended) do
      do_suspend(state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:command, "resume"}, _from, state) do
    with :ok <- validate_transition(state.status, :starting) do
      do_resume(state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:command, "destroy"}, _from, state) do
    with :ok <- validate_transition(state.status, :destroyed) do
      do_destroy(state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:command, "migrate", target}, _from, state) do
    with :ok <- validate_transition(state.status, :migrating) do
      do_migrate(state, target)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:command, "migrate", target, opts}, _from, state) do
    with :ok <- validate_transition(state.status, :migrating) do
      do_migrate(state, target, opts)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast(:health_check, state) do
    new_state = perform_health_check(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:health_check_timer, state) do
    new_state =
      state
      |> cancel_health_check_timer()
      |> perform_health_check()
      |> schedule_health_check()

    {:noreply, new_state}
  end

  def handle_info({:retry, action}, state) do
    Logger.info("MachineFSM[#{state.id}] retrying action",
      action: inspect(action),
      attempt: state.retry_count + 1
    )

    case action do
      {:start} -> do_start(state)
      {:stop} -> do_stop(state)
      {:suspend} -> do_suspend(state)
      {:resume} -> do_resume(state)
      {:migrate, target} -> do_migrate(state, target)
      {:migrate, target, opts} -> do_migrate(state, target, opts)
      _ -> {:noreply, state}
    end
  end

  def handle_info({:state_timeout, expected_version}, state) do
    if state.state_version == expected_version do
      Logger.error("MachineFSM[#{state.id}] state transition timeout",
        status: state.status,
        version: expected_version
      )

      new_state =
        transition_to(state, :error, %{
          reason: :state_timeout,
          previous_state: state.status
        })

      persist_event(new_state.id, "state_timeout", %{
        status: state.status,
        version: expected_version
      })

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:migration_progress, progress}, state) do
    Logger.debug("MachineFSM[#{state.id}] migration progress",
      phase: progress["phase"],
      progress_percent: progress["progress_percent"]
    )

    new_metadata = Map.put(state.metadata, :migration_progress, progress)
    persist_event(state.id, "migration_progress", progress)
    broadcast_update(state.id)
    {:noreply, %{state | metadata: new_metadata}}
  end

  def handle_info({:migration_complete, result}, state) do
    Logger.info("MachineFSM[#{state.id}] migration completed",
      final_state: result["final_state"]
    )

    new_status =
      case result["final_state"] do
        "STATE_COMPLETED" -> :running
        "STATE_FAILED" -> :error
        "STATE_ROLLED_BACK" -> :stopped
        _ -> :error
      end

    new_state =
      state
      |> cancel_health_check_timer()
      |> transition_to(new_status, %{migration_result: result})

    persist_db_update(new_state.id, %{
      status: Atom.to_string(new_status),
      region: state.target_region || state.region,
      last_seen_at: DateTime.utc_now()
    })

    persist_event(new_state.id, "migration_completed", result)
    broadcast_update(new_state.id)

    final_state =
      if new_status == :running do
        schedule_health_check(new_state)
      else
        new_state
      end

    {:noreply, final_state}
  end

  def handle_info({:migration_error, reason}, state) do
    Logger.error("MachineFSM[#{state.id}] migration error",
      reason: inspect(reason)
    )

    persist_event(state.id, "migration_error", %{reason: inspect(reason)})

    if state.target_region do
      schedule_retry({:migrate, state.target_region, []}, state)
    else
      new_state = transition_to(state, :error, %{reason: :migration_error})
      {:noreply, new_state}
    end
  end

  @doc false
  defp validate_transition(from, to) do
    valid_transitions = %{
      created: [:starting, :destroyed],
      starting: [:running, :error, :restarting],
      running: [:stopping, :migrating, :suspended, :health_check, :destroyed, :restarting],
      stopping: [:stopped, :error],
      stopped: [:starting, :destroyed],
      migrating: [:running, :error, :stopped],
      restarting: [:starting, :error],
      suspended: [:starting, :destroyed],
      health_check: [:running, :restarting, :error],
      error: [:restarting, :destroyed],
      destroyed: []
    }

    allowed = Map.get(valid_transitions, from, [])

    if to in allowed do
      :ok
    else
      Logger.warning("Invalid state transition attempted",
        from: from,
        to: to,
        allowed: allowed
      )

      {:error, {:invalid_transition, from, to}}
    end
  end

  defp do_start(state) do
    new_state = transition_to(state, :starting, %{action: :start})

    with {:ok, resp} <- FlydClient.start_machine(state.id) do
      final_state =
        new_state
        |> transition_to(:running, %{start_response: resp})
        |> schedule_health_check()
        |> reset_retry_count()

      persist_db_update(final_state.id, %{
        status: "running",
        last_seen_at: DateTime.utc_now()
      })

      persist_event(final_state.id, "started", resp)
      broadcast_update(final_state.id)
      {:reply, {:ok, resp}, final_state}
    else
      {:error, reason} ->
        Logger.warning("MachineFSM[#{state.id}] start failed",
          reason: inspect(reason),
          retry_count: state.retry_count
        )

        persist_event(state.id, "start_failed", %{reason: inspect(reason)})
        schedule_retry({:start}, new_state)
    end
  end

  defp do_stop(state) do
    new_state =
      state
      |> cancel_health_check_timer()
      |> transition_to(:stopping, %{action: :stop})

    case FlydClient.stop_machine(state.id) do
      {:ok, resp} ->
        final_state =
          new_state
          |> transition_to(:stopped, %{stop_response: resp})
          |> reset_retry_count()

        persist_db_update(final_state.id, %{status: "stopped"})
        persist_event(final_state.id, "stopped", resp)
        broadcast_update(final_state.id)
        {:reply, {:ok, resp}, final_state}

      {:error, reason} ->
        Logger.warning("MachineFSM[#{state.id}] stop failed",
          reason: inspect(reason)
        )

        persist_event(state.id, "stop_failed", %{reason: inspect(reason)})
        schedule_retry({:stop}, new_state)
    end
  end

  defp do_suspend(state) do
    new_state =
      state
      |> cancel_health_check_timer()
      |> transition_to(:suspended, %{action: :suspend})

    case FlydClient.stop_machine(state.id) do
      {:ok, resp} ->
        final_state = reset_retry_count(new_state)
        persist_db_update(final_state.id, %{status: "suspended"})
        persist_event(final_state.id, "suspended", resp)
        broadcast_update(final_state.id)
        {:reply, {:ok, resp}, final_state}

      {:error, reason} ->
        Logger.warning("MachineFSM[#{state.id}] suspend failed",
          reason: inspect(reason)
        )

        persist_event(state.id, "suspend_failed", %{reason: inspect(reason)})
        schedule_retry({:suspend}, new_state)
    end
  end

  defp do_resume(state) do
    do_start(state)
  end

  defp do_destroy(state) do
    new_state =
      state
      |> cancel_health_check_timer()
      |> transition_to(:destroyed, %{action: :destroy})

    persist_db_update(new_state.id, %{
      status: "destroyed",
      deleted_at: DateTime.utc_now()
    })

    persist_event(new_state.id, "destroyed", %{})
    broadcast_update(new_state.id)
    {:reply, {:ok, %{status: "destroyed"}}, new_state}
  end

  defp do_migrate(state, target, opts \\ []) do
    Logger.info("MachineFSM[#{state.id}] initiating migration",
      target: target,
      strategy: Keyword.get(opts, :strategy, "stop_and_move"),
      current_region: state.region
    )

    new_state =
      state
      |> cancel_health_check_timer()
      |> transition_to(:migrating, %{
        target_region: target,
        strategy: Keyword.get(opts, :strategy, "stop_and_move")
      })
      |> Map.put(:target_region, target)

    case FlydClient.migrate_machine(state.id, target, opts) do
      {:ok, resp} ->
        migration_id = resp["migration_id"]

        persist_db_update(new_state.id, %{
          status: "migrating",
          region: target,
          last_seen_at: DateTime.utc_now()
        })

        persist_event(new_state.id, "migrate_started", resp)
        broadcast_update(new_state.id)

        {:ok, _stream_pid} =
          FlydClient.stream_migration_progress(migration_id, fn progress ->
            send(self(), {:migration_progress, progress})
          end)

        Logger.info("MachineFSM[#{state.id}] migration initiated",
          migration_id: migration_id,
          estimated_duration_ms: resp["estimated_duration_ms"]
        )

        schedule_state_timeout(new_state)
        {:reply, {:ok, resp}, reset_retry_count(new_state)}

      {:error, {:invalid_strategy, strategy}} = error ->
        Logger.error("MachineFSM[#{state.id}] invalid migration strategy",
          strategy: strategy
        )

        persist_event(state.id, "migration_failed", %{
          reason: "invalid_strategy",
          strategy: strategy
        })

        {:reply, error, state}

      {:error, {:bad_request, reason}} = error ->
        Logger.error("MachineFSM[#{state.id}] bad migration request",
          reason: reason
        )

        persist_event(state.id, "migration_failed", %{
          reason: "bad_request",
          details: reason
        })

        {:reply, error, state}

      {:error, reason} ->
        Logger.warning("MachineFSM[#{state.id}] migration failed to start",
          reason: inspect(reason)
        )

        persist_event(state.id, "migration_start_failed", %{reason: inspect(reason)})
        schedule_retry({:migrate, target, opts}, new_state)
    end
  end

  defp perform_health_check(state) do
    Logger.debug("MachineFSM[#{state.id}] performing health check")

    case FlydClient.get_machine(state.id) do
      {:ok, machine_data} ->
        health_status = machine_data["status"] || "unknown"
        new_state = %{state | last_health_check_at: DateTime.utc_now(), health_check_failures: 0}

        Logger.debug("MachineFSM[#{state.id}] health check passed",
          status: health_status
        )

        emit_telemetry(:health_check_passed, new_state, %{health_status: health_status})
        new_state

      {:error, reason} ->
        failures = state.health_check_failures + 1

        Logger.warning("MachineFSM[#{state.id}] health check failed",
          reason: inspect(reason),
          failures: failures,
          threshold: @health_check_failure_threshold
        )

        new_state = %{
          state
          | last_health_check_at: DateTime.utc_now(),
            health_check_failures: failures
        }

        persist_event(state.id, "health_check_failed", %{
          reason: inspect(reason),
          failure_count: failures
        })

        emit_telemetry(:health_check_failed, new_state, %{
          reason: reason,
          failures: failures
        })

        if failures >= @health_check_failure_threshold do
          Logger.error(
            "MachineFSM[#{state.id}] health check threshold exceeded, initiating restart"
          )

          transition_to(new_state, :restarting, %{
            reason: :health_check_failures,
            failure_count: failures
          })
        else
          new_state
        end
    end
  end

  defp transition_to(state, new_status, metadata \\ %{}) do
    now = DateTime.utc_now()

    duration_ms =
      if state.last_transition_at do
        DateTime.diff(now, state.last_transition_at, :millisecond)
      else
        nil
      end

    transition = %{
      from: state.status,
      to: new_status,
      timestamp: now,
      metadata: metadata,
      duration_ms: duration_ms
    }

    new_history =
      [transition | state.state_history]
      |> Enum.take(@max_state_history)

    new_state = %{
      state
      | status: new_status,
        previous_status: state.status,
        state_version: state.state_version + 1,
        state_history: new_history,
        last_transition_at: now,
        metadata: Map.merge(state.metadata, metadata)
    }

    Logger.info("MachineFSM[#{state.id}] state transition",
      from: state.status,
      to: new_status,
      version: new_state.state_version,
      duration_ms: duration_ms
    )

    emit_telemetry(:state_transition, new_state, %{
      from: state.status,
      to: new_status,
      metadata: metadata
    })

    persist_event(state.id, "state_transition", %{
      from: state.status,
      to: new_status,
      version: new_state.state_version,
      metadata: metadata
    })

    new_state
  end

  defp schedule_retry(action, state) do
    if state.retry_count >= state.max_retries do
      Logger.error("MachineFSM[#{state.id}] retry limit exceeded",
        action: inspect(action),
        retries: state.retry_count
      )

      persist_event(state.id, "retry_exhausted", %{
        action: inspect(action),
        retry_count: state.retry_count
      })

      error_state =
        transition_to(state, :error, %{
          reason: :retry_exhausted,
          action: action
        })

      emit_telemetry(:retry_exhausted, error_state, %{action: action})
      {:reply, {:error, :retry_exhausted}, error_state}
    else
      base_delay = trunc(:math.pow(2, state.retry_count) * @retry_delay_ms)
      jitter = :rand.uniform(trunc(base_delay * 0.3))
      delay = min(base_delay + jitter, @max_retry_delay_ms)

      Logger.info("MachineFSM[#{state.id}] scheduling retry",
        action: inspect(action),
        attempt: state.retry_count + 1,
        delay_ms: delay
      )

      Process.send_after(self(), {:retry, action}, delay)
      new_state = %{state | retry_count: state.retry_count + 1}

      emit_telemetry(:retry_scheduled, new_state, %{
        action: action,
        delay_ms: delay
      })

      {:noreply, new_state}
    end
  end

  defp reset_retry_count(state) do
    %{state | retry_count: 0}
  end

  defp schedule_health_check(state) do
    ref = Process.send_after(self(), :health_check_timer, state.health_check_interval_ms)
    %{state | health_check_ref: ref}
  end

  defp cancel_health_check_timer(state) do
    if state.health_check_ref do
      Process.cancel_timer(state.health_check_ref)
    end

    %{state | health_check_ref: nil}
  end

  defp schedule_state_timeout(state) do
    Process.send_after(
      self(),
      {:state_timeout, state.state_version},
      @state_transition_timeout_ms
    )

    state
  end

  defp persist_event(machine_id, type, payload) do
    %MachineEvent{}
    |> MachineEvent.changeset(%{
      machine_id: machine_id,
      type: type,
      payload: payload,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  rescue
    e ->
      Logger.error("MachineFSM failed to persist event",
        machine_id: machine_id,
        type: type,
        error: inspect(e)
      )

      :ok
  end

  defp persist_db_update(id, attrs) do
    Repo.transaction(fn ->
      case Repo.get(Machine, id) do
        nil ->
          %Machine{}
          |> Machine.changeset(Map.put(attrs, "id", id))
          |> Repo.insert!()

          :ok

        m ->
          m
          |> Machine.changeset(Enum.into(attrs, %{}))
          |> Repo.update!()

          :ok
      end
    end)
  rescue
    e ->
      Logger.error("MachineFSM failed to persist DB update",
        machine_id: id,
        error: inspect(e)
      )

      {:error, :db_error}
  end

  defp broadcast_update(id) do
    case Repo.get(Machine, id) do
      nil -> :ok
      m -> Orchestrator.PubSub.publish_machine_update(m)
    end
  rescue
    _ -> :ok
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> :created
  end

  defp emit_telemetry(event_name, state, metadata \\ %{}) do
    :telemetry.execute(
      [:orchestrator, :machine_fsm, event_name],
      %{count: 1, value: 1},
      Map.merge(metadata, %{
        machine_id: state.id,
        status: state.status,
        state_version: state.state_version,
        region: state.region
      })
    )
  end
end
