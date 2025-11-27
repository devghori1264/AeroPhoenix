defmodule Orchestrator.Migration.BackpressureController do
  use GenServer
  require Logger

  def init(_), do: {:ok, %{}}

  @type rate_limit :: %{
          type: :static | :token_bucket | :adaptive,
          target_rate_mbps: float(),
          bucket: TokenBucket.t() | nil,
          adapter: AdaptiveRateAdapter.t() | nil
        }

  defmodule TokenBucket do
    defstruct [:capacity_bytes, :tokens, :refill_rate_bps, :last_refill_ms]

    @type t :: %__MODULE__{
            capacity_bytes: non_neg_integer(),
            tokens: float(),
            refill_rate_bps: float(),
            last_refill_ms: integer()
          }
    def new(capacity_mb, refill_rate_mbps) do
      capacity_bytes = capacity_mb * 1_048_576
      refill_rate_bps = refill_rate_mbps * 1_048_576

      %__MODULE__{
        capacity_bytes: capacity_bytes,
        tokens: capacity_bytes,
        refill_rate_bps: refill_rate_bps,
        last_refill_ms: System.monotonic_time(:millisecond)
      }
    end

    def consume(%__MODULE__{} = bucket, bytes) do
      now = System.monotonic_time(:millisecond)
      elapsed_s = (now - bucket.last_refill_ms) / 1000
      refilled_tokens = bucket.tokens + elapsed_s * bucket.refill_rate_bps
      current_tokens = min(bucket.capacity_bytes, refilled_tokens)

      bucket = %{bucket | tokens: current_tokens, last_refill_ms: now}

      cond do
        current_tokens >= bytes ->
          {:ok, %{bucket | tokens: current_tokens - bytes}}

        true ->
          needed = bytes - current_tokens
          wait_ms = needed / bucket.refill_rate_bps * 1000
          {:wait, round(wait_ms), bucket}
      end
    end
  end

  defmodule AdaptiveRateAdapter do
    defstruct [
      :bottleneck_bw_bps,
      :min_rtt_ms,
      :current_rate_bps,
      :max_rate_bps,
      :rtt_samples,
      :bw_samples
    ]

    @type t :: %__MODULE__{
            bottleneck_bw_bps: float(),
            min_rtt_ms: float(),
            current_rate_bps: float(),
            max_rate_bps: float(),
            rtt_samples: list(float()),
            bw_samples: list(float())
          }

    @sample_window 10

    def new(initial_rate_mbps, max_rate_mbps) do
      %__MODULE__{
        bottleneck_bw_bps: initial_rate_mbps * 1_048_576,
        min_rtt_ms: :infinity,
        current_rate_bps: initial_rate_mbps * 1_048_576,
        max_rate_bps: max_rate_mbps * 1_048_576,
        rtt_samples: [],
        bw_samples: []
      }
    end

    def update(%__MODULE__{} = adapter, bytes_sent, duration_ms, rtt_ms) do
      observed_bw = bytes_sent / duration_ms * 1000

      bw_samples = [observed_bw | adapter.bw_samples] |> Enum.take(@sample_window)
      max_bw = Enum.max(bw_samples)

      rtt_samples = [rtt_ms | adapter.rtt_samples] |> Enum.take(@sample_window)
      min_rtt = Enum.min(rtt_samples)

      avg_rtt = Enum.sum(rtt_samples) / length(rtt_samples)
      rtt_inflation = avg_rtt / min_rtt

      new_rate =
        cond do
          rtt_inflation > 1.25 ->
            adapter.current_rate_bps * 0.75

          observed_bw > adapter.current_rate_bps * 1.25 ->
            min(observed_bw, adapter.max_rate_bps)

          true ->
            min(adapter.current_rate_bps * 1.05, adapter.max_rate_bps)
        end

      %{
        adapter
        | bottleneck_bw_bps: max_bw,
          min_rtt_ms: min_rtt,
          current_rate_bps: new_rate,
          rtt_samples: rtt_samples,
          bw_samples: bw_samples
      }
    end

    def get_rate_mbps(%__MODULE__{current_rate_bps: rate}) do
      rate / 1_048_576
    end
  end

  @spec throttle(non_neg_integer(), non_neg_integer(), float(), keyword()) ::
          :ok | {:ok, TokenBucket.t()} | {:ok, AdaptiveRateAdapter.t()}
  def throttle(bytes_sent, duration_ms, target_rate_mbps, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :static)

    case strategy do
      :static ->
        static_throttle(bytes_sent, duration_ms, target_rate_mbps)

      :token_bucket ->
        bucket = Keyword.get(opts, :bucket)
        token_bucket_throttle(bytes_sent, bucket)

      :adaptive ->
        adapter = Keyword.get(opts, :adapter)
        rtt_ms = Keyword.get(opts, :rtt_ms, 50)
        adaptive_throttle(bytes_sent, duration_ms, rtt_ms, adapter)
    end
  end

  defp static_throttle(bytes_sent, actual_duration_ms, target_rate_mbps) do
    target_duration_ms = bytes_sent / (target_rate_mbps * 1_048_576) * 1000

    sleep_ms = max(0, target_duration_ms - actual_duration_ms)

    if sleep_ms > 0 do
      Logger.debug("Backpressure throttle",
        bytes_sent: bytes_sent,
        actual_ms: actual_duration_ms,
        target_ms: Float.round(target_duration_ms, 2),
        sleep_ms: Float.round(sleep_ms, 2)
      )

      Process.sleep(round(sleep_ms))
    end

    :ok
  end

  defp token_bucket_throttle(bytes_sent, bucket) do
    case TokenBucket.consume(bucket, bytes_sent) do
      {:ok, new_bucket} ->
        {:ok, new_bucket}

      {:wait, wait_ms, new_bucket} ->
        Logger.debug("Token bucket backpressure",
          bytes_sent: bytes_sent,
          wait_ms: wait_ms,
          tokens_remaining: Float.round(new_bucket.tokens / 1_048_576, 2)
        )

        Process.sleep(wait_ms)

        {:ok, final_bucket} = TokenBucket.consume(new_bucket, bytes_sent)
        {:ok, final_bucket}
    end
  end

  defp adaptive_throttle(bytes_sent, duration_ms, rtt_ms, adapter) do
    new_adapter = AdaptiveRateAdapter.update(adapter, bytes_sent, duration_ms, rtt_ms)

    current_rate_bps = new_adapter.current_rate_bps
    target_duration_ms = bytes_sent / current_rate_bps * 1000
    sleep_ms = max(0, target_duration_ms - duration_ms)

    if sleep_ms > 0 do
      Logger.debug("Adaptive backpressure",
        bytes_sent: bytes_sent,
        current_rate_mbps: Float.round(current_rate_bps / 1_048_576, 2),
        rtt_ms: rtt_ms,
        sleep_ms: Float.round(sleep_ms, 2)
      )

      Process.sleep(round(sleep_ms))
    end

    {:ok, new_adapter}
  end
end
