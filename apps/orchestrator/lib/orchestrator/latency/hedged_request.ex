defmodule Orchestrator.Latency.HedgedRequest do
  require Logger

  @type region :: String.t()
  @type request_id :: String.t()
  @type target :: {region(), node()}
  @type result :: {:ok, term()} | {:error, term()}

  @default_hedge_delay_ms 50
  @default_timeout_ms 5_000
  @max_hedge_targets 2
  @spec execute(keyword()) :: result()
  def execute(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    targets = Keyword.fetch!(opts, :targets)
    operation = Keyword.fetch!(opts, :operation)

    hedge_delay_ms = Keyword.get(opts, :hedge_delay_ms, @default_hedge_delay_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_hedges = Keyword.get(opts, :max_hedges, @max_hedge_targets)
    enable_cancellation = Keyword.get(opts, :enable_cancellation, true)

    actual_hedge_delay =
      case hedge_delay_ms do
        :adaptive -> get_adaptive_hedge_delay()
        delay when is_integer(delay) -> delay
      end

    start_time = System.monotonic_time(:millisecond)

    result =
      execute_tiered_hedging(
        request_id,
        targets,
        operation,
        actual_hedge_delay,
        timeout_ms,
        max_hedges,
        enable_cancellation
      )

    duration_ms = System.monotonic_time(:millisecond) - start_time
    record_metrics(request_id, result, duration_ms, targets)

    result
  end

  defp execute_tiered_hedging(
         request_id,
         targets,
         operation,
         hedge_delay_ms,
         timeout_ms,
         max_hedges,
         enable_cancellation
       ) do
    selected_targets = Enum.take(targets, 1 + max_hedges)

    if length(selected_targets) < 1 do
      {:error, :no_targets_available}
    else
      primary_target = Enum.at(selected_targets, 0)

      primary_task =
        Task.async(fn ->
          execute_request(request_id, primary_target, operation, :primary)
        end)

      case Task.yield(primary_task, hedge_delay_ms) do
        {:ok, {:ok, _} = result} ->
          Logger.debug("Primary request completed successfully",
            request_id: request_id,
            target: inspect(primary_target),
            duration_ms: hedge_delay_ms
          )

          result

        {:ok, {:error, _} = error} ->
          Logger.debug("Primary request failed immediately, firing hedge",
            request_id: request_id,
            target: inspect(primary_target),
            error: error
          )
          fire_hedges_and_wait(
            request_id,
            primary_task,
            selected_targets,
            operation,
            timeout_ms,
            enable_cancellation
          )

        nil ->
          fire_hedges_and_wait(
            request_id,
            primary_task,
            selected_targets,
            operation,
            timeout_ms - hedge_delay_ms,
            enable_cancellation
          )
      end
    end
  end

  defp fire_hedges_and_wait(
         request_id,
         primary_task,
         selected_targets,
         operation,
         remaining_timeout,
         enable_cancellation
       ) do
    hedge_targets = Enum.drop(selected_targets, 1)

    hedge_tasks =
      Enum.with_index(hedge_targets, 1)
      |> Enum.map(fn {target, index} ->
        Task.async(fn ->
          execute_request(request_id, target, operation, {:hedge, index})
        end)
      end)

    all_tasks = [primary_task | hedge_tasks]

    case wait_for_first_success(all_tasks, remaining_timeout) do
      {:ok, result, winning_task} ->
        if enable_cancellation do
          cancel_tasks(all_tasks -- [winning_task], request_id)
        end

        hedge_won = winning_task != primary_task

        Logger.info("Hedged request completed",
          request_id: request_id,
          hedge_won: hedge_won,
          total_targets: length(all_tasks)
        )

        result

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_request(request_id, target, operation, request_type) do
    Logger.debug("Executing request",
      request_id: request_id,
      target: inspect(target),
      type: request_type
    )

    try do
      operation.(target)
    rescue
      error ->
        Logger.error("Request failed",
          request_id: request_id,
          target: inspect(target),
          type: request_type,
          error: inspect(error)
        )

        {:error, {:request_failed, error}}
    end
  end

  defp wait_for_first_success(tasks, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_for_success(tasks, deadline, [])
  end

  defp poll_for_success([], _deadline, errors) do
    {:error, {:all_requests_failed, errors}}
  end

  defp poll_for_success(tasks, deadline, errors) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, {:all_requests_failed, [:timeout | errors]}}
    else
      poll_interval = min(10, deadline - now)
      results = Task.yield_many(tasks, poll_interval)

      success = Enum.find(results, fn {_task, result} ->
        match?({:ok, {:ok, _}}, result)
      end)

      case success do
        {winning_task, {:ok, {:ok, value}}} ->
          {:ok, {:ok, value}, winning_task}

        nil ->

          {running_tasks, new_errors} =
            Enum.reduce(results, {[], errors}, fn
              {task, nil}, {acc_tasks, acc_errors} ->
                {[task | acc_tasks], acc_errors}

              {_task, {:ok, {:error, reason}}}, {acc_tasks, acc_errors} ->
                {acc_tasks, [reason | acc_errors]}

              {_task, {:exit, reason}}, {acc_tasks, acc_errors} ->
                {acc_tasks, [{:exit, reason} | acc_errors]}

              {_task, {:ok, _other}}, {acc_tasks, acc_errors} ->
                 {acc_tasks, [:unexpected_result | acc_errors]}
            end)

          poll_for_success(Enum.reverse(running_tasks), deadline, new_errors)
      end
    end
  end

  defp cancel_tasks(tasks, request_id) do
    Enum.each(tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
    end)

    Logger.debug("Cancelled slow requests",
      request_id: request_id,
      count: length(tasks)
    )
  end

  defp get_adaptive_hedge_delay do
    case fetch_p95_latency() do
      {:ok, p95_ms} when p95_ms > 0 -> round(p95_ms)
      _ -> @default_hedge_delay_ms
    end
  end

  defp record_metrics(request_id, result, duration_ms, targets) do
    :telemetry.execute(
      [:orchestrator, :hedged_request, :completed],
      %{
        duration_ms: duration_ms,
        target_count: length(targets)
      },
      %{
        request_id: request_id,
        success: match?({:ok, _}, result)
      }
    )

    case result do
      {:ok, _} ->
        update_latency_histogram(duration_ms)

      {:error, _} ->
        :ok
    end
  end

  defp update_latency_histogram(duration_ms) do
    ensure_table_exists()

    :ets.insert(
      :hedged_request_metrics,
      {:latency, System.monotonic_time(:millisecond), duration_ms}
    )

    if :rand.uniform(100) == 1 do
      cleanup_old_metrics()
    end

    :ok
  end

  defp fetch_p95_latency do
    ensure_table_exists()
    now = System.monotonic_time(:millisecond)
    one_minute_ago = now - 60_000

    match_spec = [{{:latency, :"$1", :"$2"}, [{:>, :"$1", one_minute_ago}], [:"$2"]}]
    latencies = :ets.select(:hedged_request_metrics, match_spec)

    if Enum.empty?(latencies) do
      {:error, :no_data}
    else
      sorted = Enum.sort(latencies)
      count = length(sorted)
      index = ceil(count * 0.95) - 1
      {:ok, Enum.at(sorted, max(0, index))}
    end
  end

  defp ensure_table_exists do
    if :ets.info(:hedged_request_metrics) == :undefined do
      try do
        :ets.new(:hedged_request_metrics, [
          :named_table,
          :public,
          :bag,
          {:write_concurrency, true}
        ])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp cleanup_old_metrics do
    now = System.monotonic_time(:millisecond)
    one_minute_ago = now - 60_000
    match_spec = [{{:latency, :"$1", :_}, [{:<, :"$1", one_minute_ago}], [true]}]
    :ets.select_delete(:hedged_request_metrics, match_spec)
  end

  @spec calculate_p95_delay() :: non_neg_integer()
  def calculate_p95_delay do
    @default_hedge_delay_ms
  end

  @spec stats() :: map()
  def stats do
    %{
      total_requests: 0,
      hedge_sent: 0,
      hedge_won: 0,
      hedge_win_rate: 0.0,
      current_p95_delay: @default_hedge_delay_ms,
      wasted_capacity_pct: 0.0
    }
  end
end
