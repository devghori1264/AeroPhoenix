defmodule Orchestrator.Latency.LatencyOptimizer do
  use GenServer
  require Logger

  alias Orchestrator.Latency.{GeoRouter, HedgedRequest, RequestCoalescer}

  @type region :: atom()
  @type circuit_state :: :closed | :open | :half_open
  @type request_opts :: keyword()

  @type circuit_breaker :: %{
          state: circuit_state(),
          failure_count: non_neg_integer(),
          last_failure_at: integer() | nil,
          opened_at: integer() | nil
        }

  @type state :: %{
          circuit_breakers: %{region() => circuit_breaker()},
          latency_tracker: pid() | nil,
          coalescers: %{atom() => pid()},
          enable_hedging: boolean(),
          enable_coalescing: boolean(),
          circuit_breaker_config: map()
        }

  @circuit_breaker_defaults %{
    failure_threshold: 5,
    failure_window_ms: 60_000,
    open_timeout_ms: 60_000,
    half_open_max_requests: 1
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec execute(keyword()) :: {:ok, term()} | {:error, term()}
  def execute(opts) do
    GenServer.call(__MODULE__, {:execute, opts}, :infinity)
  end

  @spec circuit_state(region()) :: circuit_state()
  def circuit_state(region) do
    GenServer.call(__MODULE__, {:circuit_state, region})
  end

  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(opts) do
    enable_hedging = Keyword.get(opts, :enable_hedging, true)
    enable_coalescing = Keyword.get(opts, :enable_coalescing, true)

    circuit_config =
      Keyword.get(opts, :circuit_breaker_config, %{})
      |> then(&Map.merge(@circuit_breaker_defaults, &1))

    state = %{
      circuit_breakers: %{},
      latency_tracker: nil,
      coalescers: %{},
      enable_hedging: enable_hedging,
      enable_coalescing: enable_coalescing,
      circuit_breaker_config: circuit_config
    }

    Logger.info("LatencyOptimizer started",
      hedging: enable_hedging,
      coalescing: enable_coalescing
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, opts}, _from, state) do
    request = Keyword.fetch!(opts, :request)
    operation = Keyword.fetch!(opts, :operation)
    region_opt = Keyword.get(opts, :region, :auto)
    client_location = Keyword.get(opts, :client_location)

    target_region =
      if region_opt == :auto and client_location != nil do
        GeoRouter.select_best_region(client_location)
      else
        region_opt
      end

    circuit_state = get_circuit_state(state, target_region)

    result =
      case circuit_state do
        :open ->
          Logger.warning("Circuit breaker open", region: target_region)

          {:error, :circuit_open}

        :half_open ->
          execute_with_circuit_tracking(request, target_region, operation, state, opts)

        :closed ->
          execute_optimized(request, target_region, operation, state, opts)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:circuit_state, region}, _from, state) do
    circuit = Map.get(state.circuit_breakers, region, initialize_circuit_breaker())
    {:reply, circuit.state, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = compile_stats(state)
    {:reply, stats, state}
  end

  defp execute_optimized(request, region, operation, state, opts) do
    enable_hedging = Keyword.get(opts, :enable_hedging, state.enable_hedging)
    enable_coalescing = Keyword.get(opts, :enable_coalescing, state.enable_coalescing)

    executor_fn = fn ->
      {:ok, %{result: "success", region: region}}
    end

    cond do
      enable_coalescing ->
        coalescer = get_or_create_coalescer(operation, state)

        RequestCoalescer.execute(coalescer,
          request_id: extract_request_id(request),
          request: request
        )

      enable_hedging ->
        HedgedRequest.execute(primary_fn: executor_fn)

      true ->
        executor_fn.()
    end
  end

  defp execute_with_circuit_tracking(request, region, operation, state, opts) do
    result = execute_optimized(request, region, operation, state, opts)

    new_state =
      case result do
        {:ok, _} ->
          close_circuit(state, region)

        {:error, _} ->
          record_failure(state, region)
      end

    Process.put(:optimizer_state, new_state)

    result
  end

  defp get_circuit_state(state, region) do
    circuit = Map.get(state.circuit_breakers, region, initialize_circuit_breaker())
    circuit.state
  end

  defp initialize_circuit_breaker do
    %{
      state: :closed,
      failure_count: 0,
      last_failure_at: nil,
      opened_at: nil
    }
  end

  defp record_failure(state, region) do
    now = System.monotonic_time(:millisecond)
    circuit = Map.get(state.circuit_breakers, region, initialize_circuit_breaker())

    window_start = now - state.circuit_breaker_config.failure_window_ms

    failure_count =
      if circuit.last_failure_at != nil and circuit.last_failure_at >= window_start do
        circuit.failure_count + 1
      else
        1
      end

    new_state =
      if failure_count >= state.circuit_breaker_config.failure_threshold do
        :open
      else
        circuit.state
      end

    updated_circuit = %{
      circuit
      | state: new_state,
        failure_count: failure_count,
        last_failure_at: now,
        opened_at: if(new_state == :open, do: now, else: circuit.opened_at)
    }

    updated_breakers = Map.put(state.circuit_breakers, region, updated_circuit)

    Logger.warning("Circuit breaker failure recorded",
      region: region,
      failure_count: failure_count,
      state: new_state
    )

    %{state | circuit_breakers: updated_breakers}
  end

  defp close_circuit(state, region) do
    circuit = Map.get(state.circuit_breakers, region, initialize_circuit_breaker())

    updated_circuit = %{
      circuit
      | state: :closed,
        failure_count: 0,
        last_failure_at: nil,
        opened_at: nil
    }

    updated_breakers = Map.put(state.circuit_breakers, region, updated_circuit)

    Logger.info("Circuit breaker closed (recovered)", region: region)

    %{state | circuit_breakers: updated_breakers}
  end

  defp get_or_create_coalescer(operation, state) do
    case Map.get(state.coalescers, operation) do
      nil ->
        {:ok, pid} =
          RequestCoalescer.start_link(
            operation_type: operation,
            executor_fn: fn requests ->
              Map.new(requests, fn req_id -> {req_id, {:ok, %{id: req_id}}} end)
            end
          )

        pid

      pid ->
        pid
    end
  end

  defp extract_request_id(request) when is_map(request) do
    Map.get(request, :machine_id) || Map.get(request, :id) || :erlang.phash2(request)
  end

  defp extract_request_id(request), do: :erlang.phash2(request)

  defp compile_stats(state) do
    %{
      circuit_breakers:
        Map.new(state.circuit_breakers, fn {region, circuit} ->
          {region, %{state: circuit.state, failure_count: circuit.failure_count}}
        end),
      enable_hedging: state.enable_hedging,
      enable_coalescing: state.enable_coalescing
    }
  end
end
