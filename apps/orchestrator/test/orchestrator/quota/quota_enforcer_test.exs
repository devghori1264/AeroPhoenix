defmodule Orchestrator.Quota.QuotaEnforcerTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Quota.QuotaEnforcer

  setup do
    {:ok, _pid} = start_supervised(QuotaEnforcer)
    :ok
  end

  describe "check_api_quota/2" do
    test "allows requests within quota" do
      assert :ok = QuotaEnforcer.check_api_quota("org_test_1", "/api/machines")

      for _i <- 1..10 do
        assert :ok = QuotaEnforcer.check_api_quota("org_test_1", "/api/machines")
      end
    end

    test "rate limits after quota exceeded" do
      org_id = "org_rate_limit_1"

      for _i <- 1..1000 do
        QuotaEnforcer.check_api_quota(org_id, "/api/machines")
      end

      assert {:error, :rate_limited} = QuotaEnforcer.check_api_quota(org_id, "/api/machines")
    end

    test "separate quotas per organization" do
      for _i <- 1..1000 do
        QuotaEnforcer.check_api_quota("org_separate_a", "/api/machines")
      end

      assert {:error, :rate_limited} =
               QuotaEnforcer.check_api_quota("org_separate_a", "/api/machines")

      assert :ok = QuotaEnforcer.check_api_quota("org_separate_b", "/api/machines")
    end
  end

  describe "check_machine_creation_quota/1" do
    test "allows machine creation within quota" do
      org_id = "org_machine_create_1"

      assert :ok = QuotaEnforcer.check_machine_creation_quota(org_id)
    end

    test "rate limits after burst exceeded" do
      org_id = "org_machine_burst_1"

      for _i <- 1..100 do
        QuotaEnforcer.check_machine_creation_quota(org_id)
      end

      assert {:error, :rate_limited} = QuotaEnforcer.check_machine_creation_quota(org_id)
    end
  end

  describe "check_cpu_quota/2" do
    test "allows CPU usage within quota" do
      org_id = "org_cpu_1"

      assert :ok = QuotaEnforcer.check_cpu_quota(org_id, 100)
    end

    test "allows burst CPU usage" do
      org_id = "org_cpu_burst_1"

      assert :ok = QuotaEnforcer.check_cpu_quota(org_id, 36000)
    end

    test "rate limits excessive CPU usage" do
      org_id = "org_cpu_exceed_1"

      QuotaEnforcer.check_cpu_quota(org_id, 36000)

      assert {:error, :rate_limited} = QuotaEnforcer.check_cpu_quota(org_id, 1000)
    end
  end

  describe "check_memory_quota/2" do
    test "allows memory allocation within quota" do
      org_id = "org_memory_1"

      assert :ok = QuotaEnforcer.check_memory_quota(org_id, 100)
    end

    test "rate limits excessive memory allocation" do
      org_id = "org_memory_exceed_1"

      QuotaEnforcer.check_memory_quota(org_id, 1000)

      assert {:error, :rate_limited} = QuotaEnforcer.check_memory_quota(org_id, 100)
    end
  end

  describe "get_quota_stats/1" do
    test "returns quota statistics for organization" do
      org_id = "org_stats_1"

      QuotaEnforcer.check_api_quota(org_id, "/api/machines")
      QuotaEnforcer.check_machine_creation_quota(org_id)

      stats = QuotaEnforcer.get_quota_stats(org_id)

      assert is_map(stats)
      assert Map.has_key?(stats, :api_requests)
      assert Map.has_key?(stats, :machines)
      assert Map.has_key?(stats, :cpu_seconds)
      assert Map.has_key?(stats, :memory_gb)
      assert Map.has_key?(stats, :bandwidth_mbps)

      for {_resource_type, resource_stats} <- stats do
        assert Map.has_key?(resource_stats, :tokens)
        assert Map.has_key?(resource_stats, :capacity)
      end
    end
  end

  describe "telemetry events" do
    setup do
      events = [
        [:orchestrator, :quota, :usage],
        [:orchestrator, :quota, :rate_limited]
      ]

      test_pid = self()

      handler_id = "test-quota-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      :ok
    end

    test "emits usage event on successful quota check" do
      QuotaEnforcer.check_api_quota("org_telemetry_usage_1", "/api/machines")

      assert_receive {:telemetry_event, [:orchestrator, :quota, :usage], measurements, metadata},
                     1000

      assert is_number(measurements.amount)
      assert metadata.org_id == "org_telemetry_usage_1"
      assert metadata.resource_type == :api_requests
    end

    test "emits rate_limited event when quota exceeded" do
      org_id = "org_telemetry_limited_1"

      for _i <- 1..1000 do
        QuotaEnforcer.check_api_quota(org_id, "/api/machines")
      end

      QuotaEnforcer.check_api_quota(org_id, "/api/machines")

      assert_receive {:telemetry_event, [:orchestrator, :quota, :rate_limited], _measurements,
                      metadata},
                     1000

      assert metadata.org_id == org_id
      assert metadata.resource_type == :api_requests
    end
  end

  describe "quota refill behavior" do
    test "quota refills over time" do
      org_id = "org_refill_1"

      for _i <- 1..50 do
        QuotaEnforcer.check_api_quota(org_id, "/api/machines")
      end

      Process.sleep(600)

      assert :ok = QuotaEnforcer.check_api_quota(org_id, "/api/machines")
    end
  end

  describe "concurrent access" do
    test "handles concurrent quota checks safely" do
      org_id = "org_concurrent_1"

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            QuotaEnforcer.check_api_quota(org_id, "/api/endpoint_#{i}")
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, fn
               :ok -> true
               {:error, :rate_limited} -> true
               _ -> false
             end)
    end
  end
end
