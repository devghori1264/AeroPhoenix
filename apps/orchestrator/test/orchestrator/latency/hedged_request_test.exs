defmodule Orchestrator.Latency.HedgedRequestTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Latency.HedgedRequest

  describe "execute/1 - basic hedging" do
    test "primary succeeds before hedge fires" do
      operation = fn _target ->
        Process.sleep(50)
        {:ok, :primary_result}
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:ord, node()}, {:iad, node()}],
          operation: operation,
          hedge_delay_ms: 100,
          timeout_ms: 5_000
        )

      assert {:ok, :primary_result} = result
    end

    test "hedge wins when primary is slow" do
      test_pid = self()

      operation = fn {region, _node} ->
        case region do
          :ord ->
            Process.sleep(300)
            {:ok, :primary_result}

          :iad ->
            Process.sleep(50)
            send(test_pid, :hedge_executed)
            {:ok, :hedge_result}
        end
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:ord, node()}, {:iad, node()}],
          operation: operation,
          hedge_delay_ms: 100,
          timeout_ms: 5_000
        )

      assert_receive :hedge_executed, 1000
      assert {:ok, :hedge_result} = result
    end

    test "both requests fail, returns error" do
      operation = fn _target ->
        Process.sleep(50)
        {:error, :request_failed}
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:ord, node()}, {:iad, node()}],
          operation: operation,
          hedge_delay_ms: 10,
          timeout_ms: 5_000
        )

      assert {:error, _} = result
    end

    test "primary fails, hedge succeeds" do
      operation = fn {region, _node} ->
        case region do
          :ord ->
            Process.sleep(50)
            {:error, :primary_failed}

          :iad ->
            Process.sleep(50)
            {:ok, :hedge_result}
        end
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:ord, node()}, {:iad, node()}],
          operation: operation,
          hedge_delay_ms: 10,
          timeout_ms: 5_000
        )

      assert {:ok, :hedge_result} = result
    end
  end

  describe "execute/1 - tiered hedging" do
    test "sends multiple hedges to different regions" do
      operation = fn {region, _node} ->
        case region do
          :nrt ->
            Process.sleep(500)
            {:ok, :nrt_result}

          :sin ->
            Process.sleep(200)
            {:ok, :sin_result}

          :lhr ->
            Process.sleep(100)
            {:ok, :lhr_result}
        end
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:nrt, node()}, {:sin, node()}, {:lhr, node()}],
          operation: operation,
          hedge_delay_ms: 50,
          timeout_ms: 5_000,
          max_hedges: 2
        )

      assert {:ok, result_data} = result
      assert result_data in [:lhr_result, :sin_result, :nrt_result]
    end
  end

  describe "execute/1 - adaptive delay" do
    test "uses p95 latency for adaptive delay" do
      operation = fn _target ->
        Process.sleep(30)
        {:ok, :result}
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:ord, node()}, {:iad, node()}],
          operation: operation,
          hedge_delay_ms: :adaptive,
          timeout_ms: 5_000
        )

      assert {:ok, _} = result
    end
  end

  describe "execute/1 - cancellation" do
    test "cancels slower task when faster one completes" do
      test_pid = self()

      operation = fn {region, _node} ->
        case region do
          :ord ->
            Process.sleep(50)
            {:ok, :primary_result}

          :iad ->
            Process.sleep(500)
            send(test_pid, :hedge_completed)
            {:ok, :hedge_result}
        end
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:ord, node()}, {:iad, node()}],
          operation: operation,
          hedge_delay_ms: 10,
          timeout_ms: 5_000,
          enable_cancellation: true
        )

      assert {:ok, :primary_result} = result

      refute_receive :hedge_completed, 600
    end
  end

  describe "execute/1 - edge cases" do
    test "handles immediate primary failure with hedge fallback" do
      operation = fn {region, _node} ->
        case region do
          :ord ->
            {:error, :immediate_failure}

          :iad ->
            Process.sleep(50)
            {:ok, :hedge_result}
        end
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:ord, node()}, {:iad, node()}],
          operation: operation,
          hedge_delay_ms: 100,
          timeout_ms: 5_000
        )

      assert {:ok, :hedge_result} = result
    end

    test "handles zero delay (immediate hedge)" do
      operation = fn {region, _node} ->
        case region do
          :ord ->
            Process.sleep(100)
            {:ok, :primary_result}

          :iad ->
            Process.sleep(50)
            {:ok, :hedge_result}
        end
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:ord, node()}, {:iad, node()}],
          operation: operation,
          hedge_delay_ms: 0,
          timeout_ms: 5_000
        )

      assert {:ok, :hedge_result} = result
    end

    test "handles single target (no hedging)" do
      operation = fn _target ->
        Process.sleep(50)
        {:ok, :primary_result}
      end

      result =
        HedgedRequest.execute(
          request_id: "test_req_#{System.unique_integer()}",
          targets: [{:ord, node()}],
          operation: operation,
          hedge_delay_ms: 100,
          timeout_ms: 5_000
        )

      assert {:ok, :primary_result} = result
    end
  end
end
