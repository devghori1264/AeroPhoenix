defmodule Orchestrator.Quota.TokenBucketTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Quota.TokenBucket

  describe "new/1" do
    test "creates bucket with full capacity" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      assert bucket.tokens == 100
      assert bucket.capacity == 100
      assert bucket.refill_rate == 10
    end
  end

  describe "consume/2" do
    test "consumes tokens when available" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      {:ok, updated_bucket} = TokenBucket.consume(bucket, 50)

      assert updated_bucket.tokens == 50
    end

    test "returns error when insufficient tokens" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 100)

      assert {:error, :rate_limited} = TokenBucket.consume(bucket, 1)
    end

    test "allows multiple small consumptions" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 10)
      {:ok, bucket} = TokenBucket.consume(bucket, 10)
      {:ok, bucket} = TokenBucket.consume(bucket, 10)

      assert bucket.tokens == 70
    end

    test "refills before consuming" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 50)
      assert bucket.tokens == 50

      Process.sleep(1100)

      {:ok, bucket} = TokenBucket.consume(bucket, 60)
      assert bucket.tokens < 10
    end
  end

  describe "peek/1" do
    test "returns available tokens without consuming" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      assert TokenBucket.peek(bucket) == 100

      {:ok, bucket} = TokenBucket.consume(bucket, 30)

      assert TokenBucket.peek(bucket) == 70
    end

    test "peek refills before returning" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 90)
      assert bucket.tokens == 10

      Process.sleep(1100)

      tokens = TokenBucket.peek(bucket)
      assert tokens > 10
      assert tokens <= 100
    end
  end

  describe "get_stats/1" do
    test "returns bucket statistics" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      stats = TokenBucket.get_stats(bucket)

      assert stats.tokens == 100
      assert stats.capacity == 100
      assert stats.refill_rate == 10
      assert stats.utilization == 0.0
    end

    test "calculates utilization correctly" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 50)

      stats = TokenBucket.get_stats(bucket)

      assert stats.utilization == 0.5
    end

    test "utilization is 1.0 when empty" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 100)

      stats = TokenBucket.get_stats(bucket)

      assert stats.utilization == 1.0
    end
  end

  describe "refill behavior" do
    test "refills at specified rate" do
      bucket =
        TokenBucket.new(%{
          capacity: 1000,
          refill_rate: 100,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 1000)
      assert bucket.tokens == 0

      Process.sleep(1100)

      tokens = TokenBucket.peek(bucket)
      assert tokens >= 90
      assert tokens <= 110
    end

    test "caps refill at capacity" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 100,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 50)

      Process.sleep(2100)

      tokens = TokenBucket.peek(bucket)
      assert tokens == 100
    end

    test "fractional refill" do
      bucket =
        TokenBucket.new(%{
          capacity: 1000,
          refill_rate: 100,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 1000)

      Process.sleep(550)

      tokens = TokenBucket.peek(bucket)
      assert tokens >= 40
      assert tokens <= 60
    end
  end

  describe "burst vs sustained rate" do
    test "allows burst up to capacity" do
      bucket =
        TokenBucket.new(%{
          capacity: 1000,
          refill_rate: 100,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 1000)
      assert bucket.tokens == 0
    end

    test "enforces sustained rate after burst" do
      bucket =
        TokenBucket.new(%{
          capacity: 1000,
          refill_rate: 100,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 1000)

      assert {:error, :rate_limited} = TokenBucket.consume(bucket, 1)

      Process.sleep(1100)

      {:ok, _bucket} = TokenBucket.consume(bucket, 100)
    end
  end

  describe "edge cases" do
    test "handles zero tokens" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 100)

      assert bucket.tokens == 0
    end

    test "handles fractional tokens" do
      bucket =
        TokenBucket.new(%{
          capacity: 100,
          refill_rate: 10,
          refill_interval_ms: 1000
        })

      {:ok, bucket} = TokenBucket.consume(bucket, 50)

      Process.sleep(250)

      tokens = TokenBucket.peek(bucket)
      assert is_number(tokens)
      assert tokens >= 50
      assert tokens <= 55
    end
  end
end
