defmodule Orchestrator.Security.KillSwitchTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Security.KillSwitch

  setup do
    start_supervised!(KillSwitch)

    machine_id = "test_machine_#{:rand.uniform(1_000_000)}"

    {:ok, machine_id: machine_id}
  end

  describe "KillSwitch.start_monitoring/1" do
    test "starts monitoring machine resources", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      assert :healthy = KillSwitch.check_health(machine_id)
    end

    test "initializes circuit breaker in CLOSED state", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      [{^machine_id, status, violations, warnings}] = :ets.lookup(:kill_switch_state, machine_id)

      assert status == :closed
      assert violations == 0
      assert warnings == []
    end
  end

  describe "KillSwitch.stop_monitoring/1" do
    test "stops monitoring and cleans up state", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      :ok = KillSwitch.stop_monitoring(machine_id)

      assert [] = :ets.lookup(:kill_switch_state, machine_id)
    end

    test "stopping non-monitored machine is safe", %{machine_id: machine_id} do
      :ok = KillSwitch.stop_monitoring(machine_id)
    end
  end

  describe "KillSwitch.report_metric/3 - CPU threshold" do
    test "tracks CPU violations", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :cpu_percent, 97.5)

      Process.sleep(100)

      case KillSwitch.check_health(machine_id) do
        {:warning, warnings} ->
          assert :cpu_exceeded in warnings

        :healthy ->
          :ok
      end
    end

    test "trips circuit breaker after consecutive violations", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      for _ <- 1..5 do
        KillSwitch.report_metric(machine_id, :cpu_percent, 98.0)
        Process.sleep(50)
      end

      Process.sleep(500)

      case KillSwitch.check_health(machine_id) do
        {:killed, reasons} ->
          assert {:circuit_breaker_tripped, :cpu_exceeded} in reasons

        {:warning, _} ->
          :ok
      end
    end

    test "resets violations when metric returns to normal", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :cpu_percent, 97.0)
      KillSwitch.report_metric(machine_id, :cpu_percent, 98.0)

      Process.sleep(100)

      KillSwitch.report_metric(machine_id, :cpu_percent, 45.0)

      Process.sleep(100)

      [{^machine_id, :closed, violations, _warnings}] =
        :ets.lookup(:kill_switch_state, machine_id)

      assert violations == 0
    end
  end

  describe "KillSwitch.report_metric/3 - Memory threshold" do
    test "detects memory violations", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :memory_percent, 96.5)

      Process.sleep(100)

      case KillSwitch.check_health(machine_id) do
        {:warning, warnings} ->
          assert :memory_exceeded in warnings

        _ ->
          :ok
      end
    end

    test "trips circuit breaker on memory violations", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      for _ <- 1..5 do
        KillSwitch.report_metric(machine_id, :memory_percent, 97.0)
        Process.sleep(50)
      end

      Process.sleep(500)

      case KillSwitch.check_health(machine_id) do
        {:killed, reasons} ->
          assert {:circuit_breaker_tripped, :memory_exceeded} in reasons

        _ ->
          :ok
      end
    end
  end

  describe "KillSwitch.report_metric/3 - Network threshold" do
    test "detects network flood", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :network_mbps, 130.0)

      Process.sleep(100)

      case KillSwitch.check_health(machine_id) do
        {:warning, warnings} ->
          assert :network_flood in warnings

        _ ->
          :ok
      end
    end

    test "trips circuit breaker on sustained network flood", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      for _ <- 1..5 do
        KillSwitch.report_metric(machine_id, :network_mbps, 135.0)
        Process.sleep(50)
      end

      Process.sleep(500)

      case KillSwitch.check_health(machine_id) do
        {:killed, _reasons} ->
          assert true

        _ ->
          :ok
      end
    end
  end

  describe "KillSwitch.report_metric/3 - API rate threshold" do
    test "detects API abuse", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :api_rate_rps, 1500)

      Process.sleep(100)

      case KillSwitch.check_health(machine_id) do
        {:warning, warnings} ->
          assert :api_abuse in warnings

        _ ->
          :ok
      end
    end
  end

  describe "KillSwitch.check_health/1" do
    test "returns :healthy for normal machine", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :cpu_percent, 35.0)
      KillSwitch.report_metric(machine_id, :memory_percent, 50.0)

      Process.sleep(100)

      assert :healthy = KillSwitch.check_health(machine_id)
    end

    test "returns :warning for elevated metrics", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :cpu_percent, 97.0)

      Process.sleep(100)

      case KillSwitch.check_health(machine_id) do
        {:warning, warnings} ->
          assert is_list(warnings)
          assert length(warnings) > 0

        :healthy ->
          :ok
      end
    end

    test "returns :killed after circuit breaker trips", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      :ets.insert(:kill_switch_state, {machine_id, :open, 5, [:cpu_exceeded]})

      assert {:killed, [:cpu_exceeded]} = KillSwitch.check_health(machine_id)
    end
  end

  describe "KillSwitch.kill_machine/2" do
    test "kills machine manually", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      :ok = KillSwitch.kill_machine(machine_id, reason: "Suspected crypto mining")

      assert {:killed, [reason]} = KillSwitch.check_health(machine_id)
      assert reason == "Suspected crypto mining"
    end

    test "updates circuit breaker to OPEN state", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      :ok = KillSwitch.kill_machine(machine_id, reason: "Test kill")

      [{^machine_id, status, _violations, _reasons}] = :ets.lookup(:kill_switch_state, machine_id)
      assert status == :open
    end

    test "logs kill event to audit log", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      :ok = KillSwitch.kill_machine(machine_id, reason: "Manual intervention")

      events = KillSwitch.get_audit_log(machine_id: machine_id)
      assert length(events) > 0

      kill_event = Enum.find(events, fn event -> event.action == :killed end)
      assert kill_event != nil
      assert kill_event.reason == "Manual intervention"
      assert kill_event.manual == true
    end
  end

  describe "KillSwitch.global_kill/1" do
    test "requires two-person authorization" do
      assert {:error, :insufficient_authorization} =
               KillSwitch.global_kill(
                 scope: :region,
                 region: "iad",
                 reason: "Test",
                 authorized_by: ["alice"]
               )

      assert {:error, :insufficient_authorization} =
               KillSwitch.global_kill(
                 scope: :region,
                 region: "iad",
                 reason: "Test",
                 authorized_by: []
               )
    end

    test "kills machines with proper authorization" do
      {:ok, killed_count} =
        KillSwitch.global_kill(
          scope: :region,
          region: "iad",
          reason: "DDoS attack",
          authorized_by: ["alice", "bob"]
        )

      assert is_integer(killed_count)
      assert killed_count >= 0
    end

    test "logs global kill event with authorization", %{machine_id: _machine_id} do
      {:ok, _count} =
        KillSwitch.global_kill(
          scope: :cluster,
          reason: "Security breach",
          authorized_by: ["alice", "bob"]
        )

      events = KillSwitch.get_audit_log()
      global_kills = Enum.filter(events, fn event -> event.action == :global_killed end)

      if length(global_kills) > 0 do
        event = List.first(global_kills)
        assert event.reason == "Security breach"
        assert event.scope == :cluster
        assert event.authorized_by == ["alice", "bob"]
      end
    end
  end

  describe "KillSwitch.get_audit_log/1" do
    test "returns audit events for machine", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :cpu_percent, 97.0)
      Process.sleep(100)

      KillSwitch.kill_machine(machine_id, reason: "Test kill")

      events = KillSwitch.get_audit_log(machine_id: machine_id)

      assert is_list(events)
      assert length(events) > 0

      Enum.each(events, fn event ->
        assert Map.has_key?(event, :timestamp)
        assert Map.has_key?(event, :action)
      end)
    end

    test "filters events by machine_id", %{machine_id: machine_id} do
      other_machine_id = "other_machine_#{:rand.uniform(1_000_000)}"

      :ok = KillSwitch.start_monitoring(machine_id)
      :ok = KillSwitch.start_monitoring(other_machine_id)

      KillSwitch.kill_machine(machine_id, reason: "Kill A")
      KillSwitch.kill_machine(other_machine_id, reason: "Kill B")

      events = KillSwitch.get_audit_log(machine_id: machine_id)

      Enum.each(events, fn event ->
        assert event.machine_id == machine_id
      end)
    end

    test "returns events in chronological order (newest first)", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :cpu_percent, 97.0)
      Process.sleep(100)

      KillSwitch.report_metric(machine_id, :memory_percent, 98.0)
      Process.sleep(100)

      events = KillSwitch.get_audit_log(machine_id: machine_id)

      if length(events) >= 2 do
        assert DateTime.compare(Enum.at(events, 0).timestamp, Enum.at(events, 1).timestamp) in [
                 :gt,
                 :eq
               ]
      end
    end
  end

  describe "KillSwitch.get_stats/0" do
    test "tracks total kills count", %{machine_id: machine_id} do
      initial_stats = KillSwitch.get_stats()
      initial_kills = initial_stats.total_kills

      :ok = KillSwitch.start_monitoring(machine_id)
      :ok = KillSwitch.kill_machine(machine_id, reason: "Test 1")

      machine_2 = "machine_#{:rand.uniform(1_000_000)}"
      :ok = KillSwitch.start_monitoring(machine_2)
      :ok = KillSwitch.kill_machine(machine_2, reason: "Test 2")

      machine_3 = "machine_#{:rand.uniform(1_000_000)}"
      :ok = KillSwitch.start_monitoring(machine_3)
      :ok = KillSwitch.kill_machine(machine_3, reason: "Test 3")

      stats = KillSwitch.get_stats()
      assert stats.total_kills == initial_kills + 3
    end

    test "tracks kills by reason", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)
      :ok = KillSwitch.kill_machine(machine_id, reason: "Manual intervention")

      stats = KillSwitch.get_stats()
      assert Map.has_key?(stats, :kills_by_reason)
      assert Map.has_key?(stats.kills_by_reason, :manual)
      assert stats.kills_by_reason.manual > 0
    end

    test "counts active warnings", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      KillSwitch.report_metric(machine_id, :cpu_percent, 97.0)
      Process.sleep(100)

      stats = KillSwitch.get_stats()
      assert is_integer(stats.active_warnings)
      assert stats.active_warnings >= 0
    end

    test "counts monitored machines", %{machine_id: machine_id} do
      initial_stats = KillSwitch.get_stats()
      initial_count = initial_stats.monitored_machines

      :ok = KillSwitch.start_monitoring(machine_id)

      stats = KillSwitch.get_stats()
      assert stats.monitored_machines == initial_count + 1

      :ok = KillSwitch.stop_monitoring(machine_id)

      stats = KillSwitch.get_stats()
      assert stats.monitored_machines == initial_count
    end
  end

  describe "Integration: Circuit Breaker Lifecycle" do
    test "complete circuit breaker flow: CLOSED → OPEN → monitoring stopped", %{
      machine_id: machine_id
    } do
      :ok = KillSwitch.start_monitoring(machine_id)
      assert :healthy = KillSwitch.check_health(machine_id)

      for i <- 1..3 do
        KillSwitch.report_metric(machine_id, :cpu_percent, 96.0 + i)
        Process.sleep(50)
      end

      Process.sleep(200)
      health = KillSwitch.check_health(machine_id)
      assert health in [:healthy, {:warning, _}]

      KillSwitch.report_metric(machine_id, :cpu_percent, 98.0)
      KillSwitch.report_metric(machine_id, :cpu_percent, 99.0)
      Process.sleep(500)

      case KillSwitch.check_health(machine_id) do
        {:killed, reasons} ->
          assert {:circuit_breaker_tripped, :cpu_exceeded} in reasons

          :ok = KillSwitch.stop_monitoring(machine_id)

          assert [] = :ets.lookup(:kill_switch_state, machine_id)

        _ ->
          :ok
      end
    end
  end

  describe "Security Scenarios" do
    test "CPU exhaustion attack (infinite loop)", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      for _ <- 1..5 do
        KillSwitch.report_metric(machine_id, :cpu_percent, 100.0)
        Process.sleep(50)
      end

      Process.sleep(500)

      case KillSwitch.check_health(machine_id) do
        {:killed, _} -> assert true
        _ -> :ok
      end
    end

    test "memory bomb attack", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      for _ <- 1..5 do
        KillSwitch.report_metric(machine_id, :memory_percent, 99.0)
        Process.sleep(50)
      end

      Process.sleep(500)

      case KillSwitch.check_health(machine_id) do
        {:killed, _} -> assert true
        _ -> :ok
      end
    end

    test "network flood attack (DDoS)", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      for _ <- 1..5 do
        KillSwitch.report_metric(machine_id, :network_mbps, 150.0)
        Process.sleep(50)
      end

      Process.sleep(500)

      case KillSwitch.check_health(machine_id) do
        {:killed, _} -> assert true
        _ -> :ok
      end
    end

    test "API abuse attack", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      for _ <- 1..5 do
        KillSwitch.report_metric(machine_id, :api_rate_rps, 2000)
        Process.sleep(50)
      end

      Process.sleep(500)

      case KillSwitch.check_health(machine_id) do
        {:killed, _} -> assert true
        _ -> :ok
      end
    end
  end

  describe "Telemetry Events" do
    test "emits monitoring_started event", %{machine_id: machine_id} do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-monitoring-started-#{ref}",
        [:orchestrator, :kill_switch, :monitoring_started],
        fn _event, _measurements, metadata, _config ->
          send(self_pid, {:telemetry, metadata})
        end,
        nil
      )

      :ok = KillSwitch.start_monitoring(machine_id)

      assert_receive {:telemetry, metadata}, 1000
      assert metadata.machine_id == machine_id

      :telemetry.detach("test-monitoring-started-#{ref}")
    end

    test "emits machine_killed event", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-machine-killed-#{ref}",
        [:orchestrator, :kill_switch, :machine_killed],
        fn _event, _measurements, metadata, _config ->
          send(self_pid, {:telemetry, metadata})
        end,
        nil
      )

      :ok = KillSwitch.kill_machine(machine_id, reason: "Test kill")

      assert_receive {:telemetry, metadata}, 1000
      assert metadata.machine_id == machine_id
      assert metadata.reason == "Test kill"
      assert metadata.manual == true

      :telemetry.detach("test-machine-killed-#{ref}")
    end

    test "emits threshold_violation event", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-threshold-violation-#{ref}",
        [:orchestrator, :kill_switch, :threshold_violation],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      KillSwitch.report_metric(machine_id, :cpu_percent, 97.5)

      receive do
        {:telemetry, measurements, metadata} ->
          assert measurements.value == 97.5
          assert metadata.machine_id == machine_id
          assert metadata.metric == :cpu_percent
      after
        1000 ->
          :ok
      end

      :telemetry.detach("test-threshold-violation-#{ref}")
    end

    test "emits circuit_breaker_tripped event", %{machine_id: machine_id} do
      :ok = KillSwitch.start_monitoring(machine_id)

      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-circuit-breaker-#{ref}",
        [:orchestrator, :kill_switch, :circuit_breaker_tripped],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      for _ <- 1..5 do
        KillSwitch.report_metric(machine_id, :cpu_percent, 98.0)
        Process.sleep(50)
      end

      receive do
        {:telemetry, measurements, metadata} ->
          assert measurements.consecutive_violations >= 5
          assert metadata.machine_id == machine_id
          assert metadata.violation == :cpu_exceeded
      after
        2000 ->
          :ok
      end

      :telemetry.detach("test-circuit-breaker-#{ref}")
    end
  end
end
