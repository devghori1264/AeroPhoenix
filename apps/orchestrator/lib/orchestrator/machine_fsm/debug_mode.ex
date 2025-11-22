defmodule Orchestrator.MachineFSM.DebugMode do
  require Logger

  @type breakpoint :: %{
          state: String.t(),
          condition: (map() -> boolean()) | nil,
          hit_count: integer(),
          enabled: boolean()
        }
  @type debug_state :: %{
          enabled: boolean(),
          paused: boolean(),
          breakpoints: map(),
          step_mode: boolean(),
          watch_expressions: map(),
          transition_log: list(),
          pause_callback: pid() | nil
        }
  @spec init_debug_state() :: debug_state()
  def init_debug_state do
    %{
      enabled: false,
      paused: false,
      breakpoints: %{},
      step_mode: false,
      watch_expressions: %{},
      transition_log: [],
      pause_callback: nil
    }
  end

  @spec enable_debug_mode(map()) :: map()
  def enable_debug_mode(state) do
    debug_state = Map.get(state, :debug, init_debug_state())
    updated_debug = %{debug_state | enabled: true}

    Logger.info("Debug mode enabled",
      machine_id: Map.get(state, :machine_id)
    )

    Map.put(state, :debug, updated_debug)
  end

  @spec disable_debug_mode(map()) :: map()
  def disable_debug_mode(state) do
    debug_state = Map.get(state, :debug, init_debug_state())

    updated_debug = %{
      debug_state
      | enabled: false,
        paused: false,
        breakpoints: %{},
        step_mode: false
    }

    Logger.info("Debug mode disabled",
      machine_id: Map.get(state, :machine_id)
    )

    Map.put(state, :debug, updated_debug)
  end

  @spec set_breakpoint(map(), String.t(), keyword()) :: map()
  def set_breakpoint(state, target_state, opts \\ []) do
    debug_state = Map.get(state, :debug, init_debug_state())

    breakpoint = %{
      state: target_state,
      condition: Keyword.get(opts, :condition),
      hit_count: 0,
      enabled: true
    }

    updated_breakpoints = Map.put(debug_state.breakpoints, target_state, breakpoint)
    updated_debug = %{debug_state | breakpoints: updated_breakpoints}

    Logger.debug("Breakpoint set",
      machine_id: Map.get(state, :machine_id),
      state: target_state,
      conditional: breakpoint.condition != nil
    )

    Map.put(state, :debug, updated_debug)
  end

  @spec remove_breakpoint(map(), String.t()) :: map()
  def remove_breakpoint(state, target_state) do
    debug_state = Map.get(state, :debug, init_debug_state())
    updated_breakpoints = Map.delete(debug_state.breakpoints, target_state)
    updated_debug = %{debug_state | breakpoints: updated_breakpoints}

    Logger.debug("Breakpoint removed",
      machine_id: Map.get(state, :machine_id),
      state: target_state
    )

    Map.put(state, :debug, updated_debug)
  end

  @spec check_breakpoint(map(), String.t()) :: {:pause, map()} | {:continue, map()}
  def check_breakpoint(state, target_state) do
    debug_state = Map.get(state, :debug, init_debug_state())

    if debug_state.enabled do
      case Map.get(debug_state.breakpoints, target_state) do
        %{enabled: true, condition: nil} = breakpoint ->
          updated_breakpoint = %{breakpoint | hit_count: breakpoint.hit_count + 1}
          updated_breakpoints = Map.put(debug_state.breakpoints, target_state, updated_breakpoint)
          updated_debug = %{debug_state | breakpoints: updated_breakpoints, paused: true}

          Logger.info("Breakpoint hit",
            machine_id: Map.get(state, :machine_id),
            state: target_state,
            hit_count: updated_breakpoint.hit_count
          )

          notify_pause(debug_state.pause_callback, state, target_state)
          {:pause, Map.put(state, :debug, updated_debug)}

        %{enabled: true, condition: condition_fn} = breakpoint when is_function(condition_fn) ->
          if condition_fn.(state) do
            updated_breakpoint = %{breakpoint | hit_count: breakpoint.hit_count + 1}

            updated_breakpoints =
              Map.put(debug_state.breakpoints, target_state, updated_breakpoint)

            updated_debug = %{debug_state | breakpoints: updated_breakpoints, paused: true}

            Logger.info("Conditional breakpoint hit",
              machine_id: Map.get(state, :machine_id),
              state: target_state,
              hit_count: updated_breakpoint.hit_count
            )

            notify_pause(debug_state.pause_callback, state, target_state)
            {:pause, Map.put(state, :debug, updated_debug)}
          else
            {:continue, state}
          end

        _ ->
          {:continue, state}
      end
    else
      {:continue, state}
    end
  end

  @spec continue_execution(map()) :: map()
  def continue_execution(state) do
    debug_state = Map.get(state, :debug, init_debug_state())

    if debug_state.paused do
      updated_debug = %{debug_state | paused: false, step_mode: false}

      Logger.info("Execution resumed",
        machine_id: Map.get(state, :machine_id)
      )

      Map.put(state, :debug, updated_debug)
    else
      state
    end
  end

  @spec enable_step_mode(map()) :: map()
  def enable_step_mode(state) do
    debug_state = Map.get(state, :debug, init_debug_state())
    updated_debug = %{debug_state | step_mode: true, paused: false}

    Logger.info("Step mode enabled",
      machine_id: Map.get(state, :machine_id)
    )

    Map.put(state, :debug, updated_debug)
  end

  @spec step(map()) :: map()
  def step(state) do
    debug_state = Map.get(state, :debug, init_debug_state())

    if debug_state.step_mode && debug_state.paused do
      updated_debug = %{debug_state | paused: false}

      Logger.debug("Stepping to next transition",
        machine_id: Map.get(state, :machine_id)
      )

      Map.put(state, :debug, updated_debug)
    else
      state
    end
  end

  @spec check_step_mode(map()) :: {:pause, map()} | {:continue, map()}
  def check_step_mode(state) do
    debug_state = Map.get(state, :debug, init_debug_state())

    if debug_state.enabled && debug_state.step_mode && !debug_state.paused do
      updated_debug = %{debug_state | paused: true}

      Logger.debug("Step mode paused",
        machine_id: Map.get(state, :machine_id),
        current_state: Map.get(state, :current_state)
      )

      notify_pause(debug_state.pause_callback, state, Map.get(state, :current_state))
      {:pause, Map.put(state, :debug, updated_debug)}
    else
      {:continue, state}
    end
  end

  @spec add_watch(map(), String.t(), (map() -> term())) :: map()
  def add_watch(state, watch_name, watch_fn) when is_function(watch_fn, 1) do
    debug_state = Map.get(state, :debug, init_debug_state())
    updated_watches = Map.put(debug_state.watch_expressions, watch_name, watch_fn)
    updated_debug = %{debug_state | watch_expressions: updated_watches}

    Logger.debug("Watch added",
      machine_id: Map.get(state, :machine_id),
      watch: watch_name
    )

    Map.put(state, :debug, updated_debug)
  end

  @spec remove_watch(map(), String.t()) :: map()
  def remove_watch(state, watch_name) do
    debug_state = Map.get(state, :debug, init_debug_state())
    updated_watches = Map.delete(debug_state.watch_expressions, watch_name)
    updated_debug = %{debug_state | watch_expressions: updated_watches}
    Map.put(state, :debug, updated_debug)
  end

  @spec evaluate_watches(map()) :: map()
  def evaluate_watches(state) do
    debug_state = Map.get(state, :debug, init_debug_state())

    if debug_state.enabled do
      watch_results =
        debug_state.watch_expressions
        |> Enum.map(fn {name, watch_fn} ->
          try do
            result = watch_fn.(state)
            {name, {:ok, result}}
          rescue
            e ->
              {name, {:error, Exception.message(e)}}
          end
        end)
        |> Map.new()

      if map_size(watch_results) > 0 do
        Logger.debug("Watch expressions evaluated",
          machine_id: Map.get(state, :machine_id),
          results: inspect(watch_results)
        )
      end

      watch_results
    else
      %{}
    end
  end

  @spec log_transition(map(), String.t(), String.t(), String.t()) :: map()
  def log_transition(state, from_state, to_state, event) do
    debug_state = Map.get(state, :debug, init_debug_state())

    if debug_state.enabled do
      transition_entry = %{
        timestamp: DateTime.utc_now(),
        from: from_state,
        to: to_state,
        event: event,
        watch_results: evaluate_watches(state)
      }

      updated_log =
        [transition_entry | debug_state.transition_log]
        |> Enum.take(100)

      updated_debug = %{debug_state | transition_log: updated_log}
      Map.put(state, :debug, updated_debug)
    else
      state
    end
  end

  @spec get_transition_history(map()) :: list()
  def get_transition_history(state) do
    debug_state = Map.get(state, :debug, init_debug_state())
    debug_state.transition_log
  end

  @spec set_pause_callback(map(), pid()) :: map()
  def set_pause_callback(state, callback_pid) when is_pid(callback_pid) do
    debug_state = Map.get(state, :debug, init_debug_state())
    updated_debug = %{debug_state | pause_callback: callback_pid}
    Map.put(state, :debug, updated_debug)
  end

  @spec get_debug_snapshot(map()) :: map()
  def get_debug_snapshot(state) do
    debug_state = Map.get(state, :debug, init_debug_state())

    %{
      enabled: debug_state.enabled,
      paused: debug_state.paused,
      step_mode: debug_state.step_mode,
      current_state: Map.get(state, :current_state),
      breakpoints: Map.values(debug_state.breakpoints),
      watches: Map.keys(debug_state.watch_expressions),
      recent_transitions: Enum.take(debug_state.transition_log, 10),
      fsm_data: %{
        machine_id: Map.get(state, :machine_id),
        region: Map.get(state, :region),
        instance_id: Map.get(state, :instance_id),
        created_at: Map.get(state, :created_at)
      }
    }
  end

  @spec is_paused?(map()) :: boolean()
  def is_paused?(state) do
    debug_state = Map.get(state, :debug, init_debug_state())
    debug_state.enabled && debug_state.paused
  end

  defp notify_pause(nil, _state, _target_state), do: :ok

  defp notify_pause(callback_pid, state, target_state) when is_pid(callback_pid) do
    send(callback_pid, {:fsm_paused, Map.get(state, :machine_id), target_state})
    :ok
  end
end
