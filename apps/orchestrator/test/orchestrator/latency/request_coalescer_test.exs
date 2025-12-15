defmodule Orchestrator.Latency.RequestCoalescerTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Latency.RequestCoalescer

  setup do
    case start_supervised({Registry, keys: :unique, name: Orchestrator.Registry}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "start_link/1" do
    test "starts coalescer GenServer with valid config" do
      executor_fn = fn requests ->
        Map.new(requests, fn req_id -> {req_id, {:ok, %{id: req_id}}} end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_operation,
          executor_fn: executor_fn,
          batch_window_ms: 10,
          max_batch_size: 100,
          notify_pid: self()
        )

      assert Process.alive?(pid)
    end
  end

  describe "execute/2 - basic batching" do
    test "batches multiple requests within time window" do
      executor_fn = fn requests ->
        Map.new(requests, fn req_id -> {req_id, {:ok, %{result: "success_#{req_id}"}}} end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_batch,
          executor_fn: executor_fn,
          batch_window_ms: 50,
          notify_pid: self()
        )

      task1 =
        Task.async(fn ->
          RequestCoalescer.execute(pid,
            request_id: "req1",
            request: %{id: "req1"}
          )
        end)

      task2 =
        Task.async(fn ->
          RequestCoalescer.execute(pid,
            request_id: "req2",
            request: %{id: "req2"}
          )
        end)

      task3 =
        Task.async(fn ->
          RequestCoalescer.execute(pid,
            request_id: "req3",
            request: %{id: "req3"}
          )
        end)

      {:ok, result1} = Task.await(task1)
      {:ok, result2} = Task.await(task2)
      {:ok, result3} = Task.await(task3)

      assert result1 == %{result: "success_req1"}
      assert result2 == %{result: "success_req2"}
      assert result3 == %{result: "success_req3"}

      assert_receive {:batch_executed, 3, _}, 2000
    end

    test "flushes batch when max size reached" do
      executor_fn = fn requests ->
        Map.new(requests, fn req_id -> {req_id, {:ok, %{id: req_id}}} end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_max_size,
          executor_fn: executor_fn,
          batch_window_ms: 1_000,
          max_batch_size: 3,
          notify_pid: self()
        )

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            RequestCoalescer.execute(pid,
              request_id: "req#{i}",
              request: %{id: "req#{i}"}
            )
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      assert_receive {:batch_executed, 3, _}, 2000
      assert_receive {:batch_executed, 2, _}, 2000
    end
  end

  describe "execute/2 - deduplication" do
    test "deduplicates identical requests within batch window" do
      call_count = :ets.new(:call_count, [:public, :set])

      executor_fn = fn requests ->
        :ets.insert(call_count, {:count, length(requests)})
        Map.new(requests, fn req_id -> {req_id, {:ok, %{id: req_id}}} end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_dedup,
          executor_fn: executor_fn,
          batch_window_ms: 50,
          notify_pid: self()
        )

      task1 =
        Task.async(fn ->
          RequestCoalescer.execute(pid,
            request_id: "same_req",
            request: %{id: "same_req"}
          )
        end)

      task2 =
        Task.async(fn ->
          RequestCoalescer.execute(pid,
            request_id: "same_req",
            request: %{id: "same_req"}
          )
        end)

      task3 =
        Task.async(fn ->
          RequestCoalescer.execute(pid,
            request_id: "same_req",
            request: %{id: "same_req"}
          )
        end)

      {:ok, result1} = Task.await(task1)
      {:ok, result2} = Task.await(task2)
      {:ok, result3} = Task.await(task3)

      assert result1 == result2
      assert result2 == result3

      Process.sleep(100)
      [{:count, count}] = :ets.lookup(call_count, :count)
      assert count == 1
    end

    test "does not deduplicate different requests" do
      test_pid = self()

      executor_fn = fn requests ->
        send(test_pid, {:batch_requests, requests})
        Map.new(requests, fn req_id -> {req_id, {:ok, %{id: req_id}}} end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_no_dedup,
          executor_fn: executor_fn,
          batch_window_ms: 50,
          notify_pid: self()
        )

      task1 =
        Task.async(fn ->
          RequestCoalescer.execute(pid, request_id: "req1", request: %{id: "req1"})
        end)

      task2 =
        Task.async(fn ->
          RequestCoalescer.execute(pid, request_id: "req2", request: %{id: "req2"})
        end)

      task3 =
        Task.async(fn ->
          RequestCoalescer.execute(pid, request_id: "req3", request: %{id: "req3"})
        end)

      Task.await(task1)
      Task.await(task2)
      Task.await(task3)

      assert_receive {:batch_requests, requests}, 2000
      assert length(requests) == 3
      assert "req1" in requests
      assert "req2" in requests
      assert "req3" in requests
    end
  end

  describe "execute/2 - error handling" do
    test "handles partial batch failures" do
      executor_fn = fn requests ->
        Map.new(requests, fn req_id ->
          case req_id do
            "req2" -> {req_id, {:error, :not_found}}
            _ -> {req_id, {:ok, %{id: req_id}}}
          end
        end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_partial_fail,
          executor_fn: executor_fn,
          batch_window_ms: 50,
          notify_pid: self()
        )

      task1 =
        Task.async(fn ->
          RequestCoalescer.execute(pid, request_id: "req1", request: %{id: "req1"})
        end)

      task2 =
        Task.async(fn ->
          RequestCoalescer.execute(pid, request_id: "req2", request: %{id: "req2"})
        end)

      task3 =
        Task.async(fn ->
          RequestCoalescer.execute(pid, request_id: "req3", request: %{id: "req3"})
        end)

      assert {:ok, %{id: "req1"}} = Task.await(task1)
      assert {:ok, %{id: "req3"}} = Task.await(task3)

      assert {:error, :not_found} = Task.await(task2)
    end

    test "handles complete batch failure" do
      executor_fn = fn _requests ->
        raise "Network timeout"
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_batch_fail,
          executor_fn: executor_fn,
          batch_window_ms: 50,
          notify_pid: self()
        )

      task =
        Task.async(fn ->
          RequestCoalescer.execute(pid,
            request_id: "req1",
            request: %{id: "req1"}
          )
        end)

      assert {:error, :batch_failed} = Task.await(task)
    end
  end

  describe "execute/2 - timeout handling" do
    test "times out if batch takes too long" do
      executor_fn = fn _requests ->
        Process.sleep(2_000)
        %{}
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_timeout,
          executor_fn: executor_fn,
          batch_window_ms: 10,
          notify_pid: self()
        )

      result =
        RequestCoalescer.execute(pid,
          request_id: "req1",
          request: %{id: "req1"},
          timeout: 100
        )

      assert {:error, :timeout} = result
    end
  end

  describe "stats/1" do
    test "returns accurate statistics" do
      executor_fn = fn requests ->
        Map.new(requests, fn req_id -> {req_id, {:ok, %{id: req_id}}} end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_stats,
          executor_fn: executor_fn,
          batch_window_ms: 50,
          notify_pid: self()
        )

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            req_id = "req#{rem(i, 5)}"

            RequestCoalescer.execute(pid,
              request_id: req_id,
              request: %{id: req_id}
            )
          end)
        end

      Enum.each(tasks, &Task.await/1)

      Process.sleep(100)

      stats = RequestCoalescer.stats(pid)

      assert stats.operation_type == :test_stats
      assert stats.total_requests == 10
      assert stats.total_batches >= 1

      assert stats.total_deduped >= 0

      assert stats.rpc_reduction_ratio > 1.0
    end
  end

  describe "edge cases" do
    test "handles single request (no batching benefit)" do
      executor_fn = fn requests ->
        Map.new(requests, fn req_id -> {req_id, {:ok, %{id: req_id}}} end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_single,
          executor_fn: executor_fn,
          batch_window_ms: 50,
          notify_pid: self()
        )

      {:ok, _result} =
        RequestCoalescer.execute(pid,
          request_id: "req1",
          request: %{id: "req1"}
        )

      assert_receive {:batch_executed, 1, _}, 2000
    end

    test "handles empty batch gracefully" do
      test_pid = self()

      executor_fn = fn _requests ->
        send(test_pid, :batch_executed)
        %{}
      end

      {:ok, _pid} =
        RequestCoalescer.start_link(
          operation_type: :test_empty,
          executor_fn: executor_fn,
          batch_window_ms: 10,
          notify_pid: self()
        )

      Process.sleep(50)

      refute_receive :batch_executed
    end

    test "handles very large batch size limit" do
      executor_fn = fn requests ->
        Map.new(requests, fn req_id -> {req_id, {:ok, %{id: req_id}}} end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_large_limit,
          executor_fn: executor_fn,
          batch_window_ms: 50,
          max_batch_size: 10_000,
          notify_pid: self()
        )

      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            RequestCoalescer.execute(pid,
              request_id: "req#{i}",
              request: %{id: "req#{i}"}
            )
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end

    test "handles concurrent batches correctly" do
      executor_fn = fn requests ->
        Map.new(requests, fn req_id -> {req_id, {:ok, %{id: req_id}}} end)
      end

      {:ok, pid} =
        RequestCoalescer.start_link(
          operation_type: :test_concurrent,
          executor_fn: executor_fn,
          batch_window_ms: 100,
          max_batch_size: 2,
          notify_pid: self()
        )

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            RequestCoalescer.execute(pid,
              request_id: "req#{i}",
              request: %{id: "req#{i}"}
            )
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      assert length(results) == 20

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end
  end
end
