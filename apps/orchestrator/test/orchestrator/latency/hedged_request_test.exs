defmodule Orchestrator.Latency.HedgedRequestTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Latency.HedgedRequest

  describe "execute/1 - basic hedging" do
    test "primary succeeds before hedge fires" do
      primary_fn = fn ->
        Process.sleep(50)
        {:ok, :primary_result}
      end

      hedge_fn = fn ->
        Process.sleep(200)
        {:ok, :hedge_result}
      end

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_fn: hedge_fn,
          delay_ms: 100
        )

      assert {:ok, :primary_result} = result
    end

    test "hedge wins when primary is slow" do
      primary_fn = fn ->
        Process.sleep(300)
        {:ok, :primary_result}
      end

      hedge_fn = fn ->
        Process.sleep(50)
        {:ok, :hedge_result}
      end

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_fn: hedge_fn,
          delay_ms: 100
        )

      assert {:ok, :hedge_result} = result
    end

    test "both requests fail, returns primary error" do
      primary_fn = fn ->
        Process.sleep(50)
        {:error, :primary_failed}
      end

      hedge_fn = fn ->
        Process.sleep(50)
        {:error, :hedge_failed}
      end

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_fn: hedge_fn,
          delay_ms: 10
        )

      assert {:error, :primary_failed} = result
    end

    test "primary fails, hedge succeeds" do
      primary_fn = fn ->
        Process.sleep(50)
        {:error, :primary_failed}
      end

      hedge_fn = fn ->
        Process.sleep(50)
        {:ok, :hedge_result}
      end

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_fn: hedge_fn,
          delay_ms: 10
        )

      assert {:ok, :hedge_result} = result
    end
  end

  describe "execute/1 - tiered hedging" do
    test "sends multiple hedges to different regions" do
      primary_fn = fn ->
        Process.sleep(500)
        {:ok, :nrt_result}
      end

      hedge_regions = [
        {:sin,
         fn ->
           Process.sleep(200)
           {:ok, :sin_result}
         end},
        {:lhr,
         fn ->
           Process.sleep(100)
           {:ok, :lhr_result}
         end}
      ]

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_regions: hedge_regions,
          delay_ms: 50
        )

      assert {:ok, result_data} = result
      assert result_data in [:lhr_result, :sin_result]
    end
  end

  describe "execute/1 - adaptive delay" do
    test "uses p95 latency for adaptive delay" do
      :telemetry.attach(
        "test-hedge-metrics",
        [:orchestrator, :latency, :request_completed],
        fn _event, measurements, _metadata, _config ->
          send(self(), {:p95_latency, measurements[:duration_ms]})
        end,
        nil
      )

      primary_fn = fn ->
        Process.sleep(150)
        {:ok, :primary_result}
      end

      hedge_fn = fn ->
        Process.sleep(30)
        {:ok, :hedge_result}
      end

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_fn: hedge_fn,
          delay_ms: :adaptive
        )

      assert {:ok, _} = result

      :telemetry.detach("test-hedge-metrics")
    end
  end

  describe "execute/1 - cancellation" do
    test "cancels slower task when faster one completes" do
      test_pid = self()

      primary_fn = fn ->
        Process.sleep(50)
        {:ok, :primary_result}
      end

      hedge_fn = fn ->
        Process.sleep(500)
        send(test_pid, :hedge_completed)
        {:ok, :hedge_result}
      end

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_fn: hedge_fn,
          delay_ms: 10
        )

      assert {:ok, :primary_result} = result

      refute_receive :hedge_completed, 600
    end
  end

  describe "execute/1 - edge cases" do
    test "handles immediate primary failure with hedge fallback" do
      primary_fn = fn ->
        {:error, :immediate_failure}
      end

      hedge_fn = fn ->
        Process.sleep(50)
        {:ok, :hedge_result}
      end

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_fn: hedge_fn,
          delay_ms: 100
        )

      assert {:ok, :hedge_result} = result
    end

    test "handles zero delay (immediate hedge)" do
      primary_fn = fn ->
        Process.sleep(100)
        {:ok, :primary_result}
      end

      hedge_fn = fn ->
        Process.sleep(50)
        {:ok, :hedge_result}
      end

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_fn: hedge_fn,
          delay_ms: 0
        )

      assert {:ok, :hedge_result} = result
    end

    test "handles nil hedge function (no hedging)" do
      primary_fn = fn ->
        Process.sleep(50)
        {:ok, :primary_result}
      end

      result =
        HedgedRequest.execute(
          primary_fn: primary_fn,
          hedge_fn: nil,
          delay_ms: 100
        )

      assert {:ok, :primary_result} = result
    end
  end
end
