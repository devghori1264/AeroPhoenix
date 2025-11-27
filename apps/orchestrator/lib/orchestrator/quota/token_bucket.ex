defmodule Orchestrator.Quota.TokenBucket do
  @enforce_keys [:capacity, :refill_rate, :refill_interval_ms, :tokens, :last_refill]
  defstruct [:capacity, :refill_rate, :refill_interval_ms, :tokens, :last_refill]

  @type t :: %__MODULE__{
          capacity: non_neg_integer(),
          refill_rate: non_neg_integer(),
          refill_interval_ms: non_neg_integer(),
          tokens: number(),
          last_refill: integer()
        }

  @type config :: %{
          capacity: non_neg_integer(),
          refill_rate: non_neg_integer(),
          refill_interval_ms: non_neg_integer()
        }
  @spec new(config()) :: t()
  def new(config) do
    %__MODULE__{
      capacity: Map.fetch!(config, :capacity),
      refill_rate: Map.fetch!(config, :refill_rate),
      refill_interval_ms: Map.fetch!(config, :refill_interval_ms),
      tokens: Map.fetch!(config, :capacity),
      last_refill: System.monotonic_time(:millisecond)
    }
  end

  @spec consume(t(), number()) :: {:ok, t()} | {:error, :rate_limited}
  def consume(bucket, amount) when amount > 0 do
    bucket = refill(bucket)

    if bucket.tokens >= amount do
      updated_bucket = %{bucket | tokens: bucket.tokens - amount}
      {:ok, updated_bucket}
    else
      {:error, :rate_limited}
    end
  end

  @spec peek(t()) :: number()
  def peek(bucket) do
    bucket = refill(bucket)
    bucket.tokens
  end

  @spec get_stats(t()) :: map()
  def get_stats(bucket) do
    bucket = refill(bucket)

    %{
      tokens: bucket.tokens,
      capacity: bucket.capacity,
      utilization: 1.0 - bucket.tokens / bucket.capacity,
      refill_rate: bucket.refill_rate
    }
  end

  def refill(bucket) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = now - bucket.last_refill

    refill_periods = elapsed_ms / bucket.refill_interval_ms
    tokens_to_add = bucket.refill_rate * refill_periods

    new_tokens = min(bucket.capacity, bucket.tokens + tokens_to_add)

    %{bucket | tokens: new_tokens, last_refill: now}
  end
end
