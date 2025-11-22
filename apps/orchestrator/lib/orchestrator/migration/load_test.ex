defmodule Orchestrator.Migration.LoadTest do
  require Logger
  alias Orchestrator.FlydClient

  defmodule LoadTestResult do
    @moduledoc false
    defstruct [
      :test_type,
      :start_time,
      :end_time,
      :duration_ms,
      :total_requests,
      :successful_requests,
      :failed_requests,
      :circuit_breaker_rejections,
      :avg_response_time_ms,
      :p50_response_time_ms,
      :p95_response_time_ms,
      :p99_response_time_ms,
      :max_response_time_ms,
      :requests_per_second,
      :errors_by_type,
      :concurrent_peak,
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            test_type: atom(),
            start_time: DateTime.t(),
            end_time: DateTime.t(),
            duration_ms: non_neg_integer(),
            total_requests: non_neg_integer(),
            successful_requests: non_neg_integer(),
            failed_requests: non_neg_integer(),
            circuit_breaker_rejections: non_neg_integer(),
            avg_response_time_ms: float(),
            p50_response_time_ms: float(),
            p95_response_time_ms: float(),
            p99_response_time_ms: float(),
            max_response_time_ms: non_neg_integer(),
            requests_per_second: float(),
            errors_by_type: map(),
            concurrent_peak: non_neg_integer(),
            metadata: map()
          }
  end

  def run_basic_load_test(opts \\ []) do
    concurrent = Keyword.get(opts, :concurrent_migrations, 10)
    duration_sec = Keyword.get(opts, :duration_seconds, 60)
    regions = Keyword.get(opts, :regions, ["us-east-1", "eu-west-1", "ap-south-1"])

    Logger.info("Starting basic load test",
      concurrent: concurrent,
      duration_seconds: duration_sec
    )

    start_time = DateTime.utc_now()
    start_monotonic = System.monotonic_time(:millisecond)
    machines = create_test_machines(concurrent, "us-east-1")
    results_collector = spawn_results_collector()

    tasks =
      Enum.map(machines, fn machine_id ->
        Task.async(fn ->
          run_migration_worker(
            machine_id,
            regions,
            duration_sec * 1000,
            results_collector
          )
        end)
      end)

    Task.await_many(tasks, (duration_sec + 30) * 1000)
    send(results_collector, {:collect, self()})

    receive do
      {:results, measurements} ->
        end_monotonic = System.monotonic_time(:millisecond)

        result =
          analyze_measurements(
            :basic_load,
            measurements,
            start_time,
            DateTime.utc_now(),
            end_monotonic - start_monotonic,
            %{concurrent_migrations: concurrent}
          )

        print_results(result)
        {:ok, result}
    after
      5000 ->
        {:error, :timeout_collecting_results}
    end
  end

  def run_stress_test(opts \\ []) do
    ramp_up_sec = Keyword.get(opts, :ramp_up_seconds, 30)
    peak_load = Keyword.get(opts, :peak_load, 50)
    duration_sec = Keyword.get(opts, :duration_seconds, 180)
    ramp_down_sec = Keyword.get(opts, :ramp_down_seconds, 30)

    Logger.info("Starting stress test",
      ramp_up: ramp_up_sec,
      peak_load: peak_load,
      duration: duration_sec
    )

    start_time = DateTime.utc_now()
    start_monotonic = System.monotonic_time(:millisecond)
    results_collector = spawn_results_collector()
    Logger.info("Stress test: ramp up phase")
    ramp_up_tasks = spawn_ramp_up_workers(peak_load, ramp_up_sec, results_collector)
    Logger.info("Stress test: sustain phase at peak load")
    sustain_duration = duration_sec - ramp_up_sec - ramp_down_sec
    Process.sleep(sustain_duration * 1000)
    Logger.info("Stress test: ramp down phase")
    Task.await_many(ramp_up_tasks, (duration_sec + 60) * 1000)
    send(results_collector, {:collect, self()})

    receive do
      {:results, measurements} ->
        end_monotonic = System.monotonic_time(:millisecond)

        result =
          analyze_measurements(
            :stress_test,
            measurements,
            start_time,
            DateTime.utc_now(),
            end_monotonic - start_monotonic,
            %{
              ramp_up_seconds: ramp_up_sec,
              peak_load: peak_load
            }
          )

        print_results(result)
        {:ok, result}
    after
      10000 ->
        {:error, :timeout_collecting_results}
    end
  end

  def run_chaos_test(opts \\ []) do
    failure_rate = Keyword.get(opts, :failure_rate, 0.2)
    duration_sec = Keyword.get(opts, :duration_seconds, 120)
    concurrent = Keyword.get(opts, :concurrent_migrations, 20)
    Logger.warning("Starting chaos test with #{failure_rate * 100}% failure rate")
    start_time = DateTime.utc_now()
    start_monotonic = System.monotonic_time(:millisecond)
    results_collector = spawn_results_collector()
    machines = create_test_machines(concurrent, "us-east-1")

    tasks =
      Enum.map(machines, fn machine_id ->
        Task.async(fn ->
          run_chaos_migration_worker(
            machine_id,
            failure_rate,
            duration_sec * 1000,
            results_collector
          )
        end)
      end)

    Task.await_many(tasks, (duration_sec + 60) * 1000)
    send(results_collector, {:collect, self()})

    receive do
      {:results, measurements} ->
        end_monotonic = System.monotonic_time(:millisecond)

        result =
          analyze_measurements(
            :chaos_test,
            measurements,
            start_time,
            DateTime.utc_now(),
            end_monotonic - start_monotonic,
            %{
              failure_rate: failure_rate,
              concurrent_migrations: concurrent
            }
          )

        print_results(result)
        {:ok, result}
    after
      10000 ->
        {:error, :timeout_collecting_results}
    end
  end

  defp create_test_machines(count, region) do
    Logger.info("Creating #{count} test machines in #{region}")

    1..count
    |> Task.async_stream(
      fn i ->
        name = "loadtest-#{System.unique_integer([:positive])}-#{i}"
        payload = %{name: name, region: region}
        url = "http://localhost:8080/create"
        headers = [{"content-type", "application/json"}]
        body = Jason.encode!(payload)

        case Finch.build(:post, url, headers, body)
             |> Finch.request(Orchestrator.Finch) do
          {:ok, %{status: 200, body: response_body}} ->
            {:ok, decoded} = Jason.decode(response_body)
            decoded["id"]

          _ ->
            nil
        end
      end,
      timeout: 30_000,
      max_concurrency: 10
    )
    |> Enum.map(fn {:ok, machine_id} -> machine_id end)
    |> Enum.filter(& &1)
  end

  defp spawn_results_collector do
    spawn(fn -> results_collector_loop([]) end)
  end

  defp results_collector_loop(measurements) do
    receive do
      {:measurement, measurement} ->
        results_collector_loop([measurement | measurements])

      {:collect, from} ->
        send(from, {:results, measurements})
        results_collector_loop(measurements)
    end
  end

  defp run_migration_worker(machine_id, regions, duration_ms, collector) do
    end_time = System.monotonic_time(:millisecond) + duration_ms
    run_migration_loop(machine_id, regions, end_time, collector, 0)
  end

  defp run_migration_loop(machine_id, regions, end_time, collector, iteration) do
    if System.monotonic_time(:millisecond) < end_time do
      target_region = Enum.at(regions, rem(iteration, length(regions)))
      start = System.monotonic_time(:millisecond)
      result = FlydClient.migrate_machine(machine_id, target_region)
      duration = System.monotonic_time(:millisecond) - start

      measurement = %{
        duration_ms: duration,
        result: result,
        timestamp: DateTime.utc_now()
      }

      send(collector, {:measurement, measurement})
      Process.sleep(500)
      run_migration_loop(machine_id, regions, end_time, collector, iteration + 1)
    end
  end

  defp spawn_ramp_up_workers(peak_load, ramp_up_sec, collector) do
    interval_ms = div(ramp_up_sec * 1000, peak_load)

    1..peak_load
    |> Enum.map(fn i ->
      Process.sleep(interval_ms)

      Task.async(fn ->
        machine_id = "rampup-machine-#{i}-#{System.unique_integer([:positive])}"
        regions = ["us-east-1", "eu-west-1", "ap-south-1"]
        run_migration_worker(machine_id, regions, 60_000, collector)
      end)
    end)
  end

  defp run_chaos_migration_worker(machine_id, failure_rate, duration_ms, collector) do
    end_time = System.monotonic_time(:millisecond) + duration_ms
    run_chaos_loop(machine_id, failure_rate, end_time, collector)
  end

  defp run_chaos_loop(machine_id, failure_rate, end_time, collector) do
    if System.monotonic_time(:millisecond) < end_time do
      start = System.monotonic_time(:millisecond)

      result =
        if :rand.uniform() < failure_rate do
          {:error, :chaos_injected_failure}
        else
          FlydClient.migrate_machine(machine_id, "eu-west-1")
        end

      duration = System.monotonic_time(:millisecond) - start

      send(
        collector,
        {:measurement,
         %{
           duration_ms: duration,
           result: result,
           timestamp: DateTime.utc_now()
         }}
      )

      Process.sleep(1000)
      run_chaos_loop(machine_id, failure_rate, end_time, collector)
    end
  end

  defp analyze_measurements(test_type, measurements, start_time, end_time, duration_ms, metadata) do
    total = length(measurements)

    {successful, failed, circuit_breaker_rejected} =
      Enum.reduce(measurements, {0, 0, 0}, fn
        %{result: {:ok, _}}, {s, f, cb} -> {s + 1, f, cb}
        %{result: {:error, :circuit_open}}, {s, f, cb} -> {s, f, cb + 1}
        %{result: {:error, _}}, {s, f, cb} -> {s, f + 1, cb}
      end)

    durations = Enum.map(measurements, & &1.duration_ms) |> Enum.sort()
    avg_duration = if total > 0, do: Enum.sum(durations) / total, else: 0
    p50 = percentile(durations, 0.50)
    p95 = percentile(durations, 0.95)
    p99 = percentile(durations, 0.99)
    max_duration = if total > 0, do: Enum.max(durations), else: 0
    rps = if duration_ms > 0, do: total / (duration_ms / 1000), else: 0

    errors_by_type =
      measurements
      |> Enum.filter(fn %{result: result} -> match?({:error, _}, result) end)
      |> Enum.group_by(fn %{result: {:error, reason}} -> reason end)
      |> Enum.map(fn {reason, list} -> {reason, length(list)} end)
      |> Map.new()

    %LoadTestResult{
      test_type: test_type,
      start_time: start_time,
      end_time: end_time,
      duration_ms: duration_ms,
      total_requests: total,
      successful_requests: successful,
      failed_requests: failed,
      circuit_breaker_rejections: circuit_breaker_rejected,
      avg_response_time_ms: avg_duration,
      p50_response_time_ms: p50,
      p95_response_time_ms: p95,
      p99_response_time_ms: p99,
      max_response_time_ms: max_duration,
      requests_per_second: rps,
      errors_by_type: errors_by_type,
      concurrent_peak:
        Map.get(metadata, :peak_load, Map.get(metadata, :concurrent_migrations, 0)),
      metadata: metadata
    }
  end

  defp percentile([], _), do: 0

  defp percentile(sorted_list, percentile) when percentile >= 0 and percentile <= 1 do
    index = round(length(sorted_list) * percentile) - 1
    index = max(0, min(index, length(sorted_list) - 1))
    Enum.at(sorted_list, index)
  end

  defp print_results(%LoadTestResult{} = result) do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("Load Test Results - #{result.test_type}")
    IO.puts(String.duplicate("=", 80))
    IO.puts("")
    IO.puts("Duration: #{result.duration_ms}ms (#{Float.round(result.duration_ms / 1000, 2)}s)")
    IO.puts("Total Requests: #{result.total_requests}")

    IO.puts(
      "Successful: #{result.successful_requests} (#{percentage(result.successful_requests, result.total_requests)}%)"
    )

    IO.puts(
      "Failed: #{result.failed_requests} (#{percentage(result.failed_requests, result.total_requests)}%)"
    )

    IO.puts("Circuit Breaker Rejected: #{result.circuit_breaker_rejections}")
    IO.puts("")
    IO.puts("Performance:")
    IO.puts("  Requests/sec: #{Float.round(result.requests_per_second, 2)}")
    IO.puts("  Avg Response Time: #{Float.round(result.avg_response_time_ms, 2)}ms")
    IO.puts("  P50: #{Float.round(result.p50_response_time_ms, 2)}ms")
    IO.puts("  P95: #{Float.round(result.p95_response_time_ms, 2)}ms")
    IO.puts("  P99: #{Float.round(result.p99_response_time_ms, 2)}ms")
    IO.puts("  Max: #{result.max_response_time_ms}ms")
    IO.puts("")

    if map_size(result.errors_by_type) > 0 do
      IO.puts("Errors by Type:")

      Enum.each(result.errors_by_type, fn {type, count} ->
        IO.puts("  #{inspect(type)}: #{count}")
      end)

      IO.puts("")
    end

    IO.puts(String.duplicate("=", 80))
    IO.puts("")
  end

  defp percentage(part, total) when total > 0 do
    Float.round(part / total * 100, 2)
  end

  defp percentage(_, _), do: 0
end
