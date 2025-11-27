defmodule Orchestrator.Migration.CircuitBreaker do
  use GenServer
  require Logger
  @type state :: :closed | :open | :half_open
  @type circuit_name :: atom() | String.t()
  defmodule Circuit do
    defstruct [
      :name,
      :state,
      :failure_count,
      :success_count,
      :last_failure_time,
      :opened_at,
      :failure_threshold,
      :timeout_ms,
      :success_threshold,
      :window_ms,
      :recent_failures
    ]

    @type t :: %__MODULE__{
            name: atom(),
            state: :closed | :open | :half_open,
            failure_count: non_neg_integer(),
            success_count: non_neg_integer(),
            last_failure_time: integer() | nil,
            opened_at: integer() | nil,
            failure_threshold: pos_integer(),
            timeout_ms: pos_integer(),
            success_threshold: pos_integer(),
            window_ms: pos_integer(),
            recent_failures: list({integer(), term()})
          }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec call(circuit_name(), (-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call(circuit_name, fun, opts \\ []) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:call, circuit_name, fun, opts}, 30_000)
  end

  @spec get_state(circuit_name()) :: state()
  def get_state(circuit_name) do
    GenServer.call(__MODULE__, {:get_state, circuit_name})
  end

  @spec reset(circuit_name()) :: :ok
  def reset(circuit_name) do
    GenServer.call(__MODULE__, {:reset, circuit_name})
  end

  @spec get_stats(circuit_name()) :: map()
  def get_stats(circuit_name) do
    GenServer.call(__MODULE__, {:get_stats, circuit_name})
  end

  @impl true
  def init(_opts) do
    :ets.new(:circuit_breaker_circuits, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    Logger.info("CircuitBreaker started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:call, circuit_name, fun, opts}, _from, state) do
    circuit = get_or_create_circuit(circuit_name, opts)

    case circuit.state do
      :open ->
        if should_attempt_reset?(circuit) do
          circuit = transition_to_half_open(circuit)
          execute_with_circuit(circuit, fun)
        else
          {:reply, {:error, :circuit_open}, state}
        end

      :half_open ->
        execute_with_circuit(circuit, fun)

      :closed ->
        execute_with_circuit(circuit, fun)
    end
    |> case do
      {result, updated_circuit} ->
        save_circuit(updated_circuit)
        {:reply, result, state}

      {:reply, result, state} ->
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:get_state, circuit_name}, _from, state) do
    circuit = get_or_create_circuit(circuit_name, [])
    {:reply, circuit.state, state}
  end

  @impl true
  def handle_call({:reset, circuit_name}, _from, state) do
    circuit = get_or_create_circuit(circuit_name, [])
    circuit = reset_circuit(circuit)
    save_circuit(circuit)
    Logger.info("Circuit reset manually", circuit: circuit_name)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_stats, circuit_name}, _from, state) do
    circuit = get_or_create_circuit(circuit_name, [])

    stats = %{
      state: circuit.state,
      failure_count: circuit.failure_count,
      success_count: circuit.success_count,
      last_failure_time: circuit.last_failure_time,
      opened_at: circuit.opened_at,
      failure_threshold: circuit.failure_threshold,
      recent_failures_count: length(circuit.recent_failures),
      uptime_ms:
        if(circuit.opened_at,
          do: System.monotonic_time(:millisecond) - circuit.opened_at,
          else: nil
        )
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup_old_failures, state) do
    cleanup_old_failures()
    schedule_cleanup()
    {:noreply, state}
  end

  defp execute_with_circuit(circuit, fun) do
    start_time = System.monotonic_time(:millisecond)

    try do
      case fun.() do
        {:ok, result} ->
          duration = System.monotonic_time(:millisecond) - start_time

          Logger.debug("Circuit call succeeded",
            circuit: circuit.name,
            state: circuit.state,
            duration_ms: duration
          )

          updated_circuit = record_success(circuit)
          {{:ok, result}, updated_circuit}

        {:error, reason} = error ->
          duration = System.monotonic_time(:millisecond) - start_time

          Logger.warning("Circuit call failed",
            circuit: circuit.name,
            state: circuit.state,
            reason: inspect(reason),
            duration_ms: duration
          )

          updated_circuit = record_failure(circuit, reason)
          {error, updated_circuit}
      end
    rescue
      exception ->
        duration = System.monotonic_time(:millisecond) - start_time

        Logger.error("Circuit call raised exception",
          circuit: circuit.name,
          exception: Exception.format(:error, exception, __STACKTRACE__),
          duration_ms: duration
        )

        updated_circuit = record_failure(circuit, {:exception, exception})
        {{:error, {:exception, exception}}, updated_circuit}
    end
  end

  defp record_success(circuit) do
    case circuit.state do
      :half_open ->
        new_success_count = circuit.success_count + 1

        if new_success_count >= circuit.success_threshold do
          Logger.info("Circuit closed after recovery",
            circuit: circuit.name,
            success_count: new_success_count
          )

          reset_circuit(circuit)
        else
          %{circuit | success_count: new_success_count}
        end

      _ ->
        %{circuit | failure_count: 0, recent_failures: []}
    end
  end

  defp record_failure(circuit, reason) do
    now = System.monotonic_time(:millisecond)
    recent_failures = [{now, reason} | circuit.recent_failures]
    window_start = now - circuit.window_ms
    recent_failures = Enum.filter(recent_failures, fn {time, _} -> time >= window_start end)
    new_failure_count = length(recent_failures)

    circuit = %{
      circuit
      | failure_count: new_failure_count,
        last_failure_time: now,
        recent_failures: recent_failures
    }

    case circuit.state do
      :closed ->
        if new_failure_count >= circuit.failure_threshold do
          Logger.warning("Circuit opened due to failures",
            circuit: circuit.name,
            failure_count: new_failure_count,
            threshold: circuit.failure_threshold,
            recent_failures: Enum.map(recent_failures, fn {_t, r} -> inspect(r) end)
          )

          :telemetry.execute(
            [:orchestrator, :circuit_breaker, :opened],
            %{failure_count: new_failure_count},
            %{circuit: circuit.name}
          )

          %{circuit | state: :open, opened_at: now, success_count: 0}
        else
          circuit
        end

      :half_open ->
        Logger.warning("Circuit reopened during half-open test",
          circuit: circuit.name
        )

        %{circuit | state: :open, opened_at: now, success_count: 0}

      :open ->
        circuit
    end
  end

  defp should_attempt_reset?(circuit) do
    now = System.monotonic_time(:millisecond)
    circuit.opened_at && now - circuit.opened_at >= circuit.timeout_ms
  end

  defp transition_to_half_open(circuit) do
    Logger.info("Circuit transitioning to half-open",
      circuit: circuit.name,
      time_open_ms: System.monotonic_time(:millisecond) - circuit.opened_at
    )

    :telemetry.execute(
      [:orchestrator, :circuit_breaker, :half_open],
      %{},
      %{circuit: circuit.name}
    )

    %{circuit | state: :half_open, success_count: 0}
  end

  defp reset_circuit(circuit) do
    :telemetry.execute(
      [:orchestrator, :circuit_breaker, :closed],
      %{},
      %{circuit: circuit.name}
    )

    %{
      circuit
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        last_failure_time: nil,
        opened_at: nil,
        recent_failures: []
    }
  end

  defp get_or_create_circuit(name, opts) do
    case :ets.lookup(:circuit_breaker_circuits, name) do
      [{^name, circuit}] ->
        circuit

      [] ->
        create_circuit(name, opts)
    end
  end

  defp create_circuit(name, opts) do
    circuit = %Circuit{
      name: name,
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      opened_at: nil,
      failure_threshold: Keyword.get(opts, :failure_threshold, 5),
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
      success_threshold: Keyword.get(opts, :success_threshold, 2),
      window_ms: Keyword.get(opts, :window_ms, 60_000),
      recent_failures: []
    }

    save_circuit(circuit)
    circuit
  end

  defp save_circuit(circuit) do
    :ets.insert(:circuit_breaker_circuits, {circuit.name, circuit})
    circuit
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_old_failures, 60_000)
  end

  defp cleanup_old_failures do
    now = System.monotonic_time(:millisecond)
    circuits = :ets.tab2list(:circuit_breaker_circuits)

    Enum.each(circuits, fn {_name, circuit} ->
      window_start = now - circuit.window_ms

      recent_failures =
        Enum.filter(circuit.recent_failures, fn {time, _} -> time >= window_start end)

      if length(recent_failures) < length(circuit.recent_failures) do
        updated_circuit = %{
          circuit
          | recent_failures: recent_failures,
            failure_count: length(recent_failures)
        }

        save_circuit(updated_circuit)
      end
    end)
  end
end
