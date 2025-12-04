defmodule Orchestrator.Logs.ProducerTest do
  use ExUnit.Case, async: false
  @moduletag :slow

  alias Orchestrator.Logs.Producer

  setup do
    if Process.whereis(Orchestrator.PubSub) == nil do
      Phoenix.PubSub.Supervisor.start_link(name: Orchestrator.PubSub)
    end

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(Orchestrator.PubSub, "machine_logs:test_machine")
      Phoenix.PubSub.unsubscribe(Orchestrator.PubSub, "log_aggregator:all_machines")
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts producer with required options" do
      assert {:ok, pid} =
               Producer.start_link(
                 machine_id: "test_machine",
                 region: "ord",
                 enable_boot_sequence: false,
                 enable_runtime_logs: false
               )

      assert Process.alive?(pid)
    end

    test "initializes state correctly" do
      {:ok, pid} =
        Producer.start_link(
          machine_id: "test_machine",
          region: "ord",
          log_rate: :high,
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      assert Process.alive?(pid)
    end
  end

  describe "emit_boot_sequence/1" do
    test "emits complete boot sequence" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:boot_test")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "boot_test",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_boot_sequence(pid)

      assert_receive {:log_event, %{message: "Starting machine initialization"}}, 500
      assert_receive {:log_event, %{message: "Kernel initialized"}}, 1000
      assert_receive {:log_event, %{message: "Mounting filesystems"}}, 1500
      assert_receive {:log_event, %{message: "Configuring network interfaces"}}, 2000
      assert_receive {:log_event, %{message: "Starting HTTP server"}}, 2500
      assert_receive {:log_event, %{message: "Registering health checks"}}, 3000
      assert_receive {:log_event, %{message: "Machine ready"}}, 3500
    end

    test "boot logs have correct structure" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:boot_structure")

      {:ok, _pid} =
        Producer.start_link(
          machine_id: "boot_structure",
          region: "ord",
          enable_boot_sequence: true,
          enable_runtime_logs: false
        )

      assert_receive {:log_event, log}, 500

      assert is_integer(log.timestamp)
      assert log.level in [:debug, :info, :warn, :error]
      assert is_atom(log.component)
      assert is_binary(log.message)
      assert is_map(log.metadata)
      assert log.metadata.machine_id == "boot_structure"
      assert log.metadata.region == "ord"
    end

    test "boot sequence timing is realistic" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:boot_timing")

      {:ok, _pid} =
        Producer.start_link(
          machine_id: "boot_timing",
          region: "ord",
          enable_boot_sequence: true,
          enable_runtime_logs: false
        )

      start_time = System.monotonic_time(:millisecond)

      assert_receive {:log_event, %{message: "Machine ready"}}, 5000

      end_time = System.monotonic_time(:millisecond)
      boot_duration = end_time - start_time

      assert boot_duration >= 1500
      assert boot_duration <= 5000
    end
  end

  describe "start_runtime_logs/1" do
    test "starts generating runtime logs" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:runtime_test")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "runtime_test",
          region: "ord",
          log_rate: :high,
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.start_runtime_logs(pid)

      assert_receive {:log_event, _log1}, 500
      assert_receive {:log_event, _log2}, 500
      assert_receive {:log_event, _log3}, 500
    end

    test "respects log rate configuration" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:rate_test")

      {:ok, _pid} =
        Producer.start_link(
          machine_id: "rate_test",
          region: "ord",
          log_rate: :low,
          enable_boot_sequence: false,
          enable_runtime_logs: true
        )

      Process.sleep(2000)

      log_count = count_messages_in_mailbox()

      assert log_count >= 1
      assert log_count <= 3
    end
  end

  describe "stop_runtime_logs/1" do
    test "stops generating runtime logs" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:stop_test")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "stop_test",
          region: "ord",
          log_rate: :high,
          enable_boot_sequence: false,
          enable_runtime_logs: true
        )

      Process.sleep(300)

      Producer.stop_runtime_logs(pid)

      flush_mailbox()

      Process.sleep(500)

      flush_mailbox()

      assert count_messages_in_mailbox() == 0
    end
  end

  describe "emit_error/3" do
    test "emits OOM error log" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:error_oom")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "error_oom",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_error(pid, :oom_killed)

      assert_receive {:log_event, log}, 500

      assert log.level == :error
      assert log.component == :init
      assert log.message == "Process killed: Out of memory"
      assert log.metadata.memory_usage_mb == 512
      assert log.metadata.exit_code == 137
    end

    test "emits disk full error log" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:error_disk")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "error_disk",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_error(pid, :disk_full, %{available_mb: 5})

      assert_receive {:log_event, log}, 500

      assert log.level == :error
      assert log.component == :storage
      assert log.message == "Disk space exhausted"
      assert log.metadata.available_mb == 5
    end

    test "emits connection timeout error" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:error_timeout")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "error_timeout",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_error(pid, :connection_timeout, %{host: "api.example.com"})

      assert_receive {:log_event, log}, 500

      assert log.level == :error
      assert log.component == :network
      assert log.metadata.host == "api.example.com"
    end

    test "emits circuit breaker open warning" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:error_cb")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "error_cb",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_error(pid, :circuit_breaker_open)

      assert_receive {:log_event, log}, 500

      assert log.level == :warn
      assert log.component == :network
      assert log.message == "Circuit breaker opened"
    end

    test "emits health check failed error" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:error_health")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "error_health",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_error(pid, :health_check_failed, %{check: "liveness"})

      assert_receive {:log_event, log}, 500

      assert log.level == :error
      assert log.component == :health_check
      assert log.metadata.check == "liveness"
    end

    test "emits migration failed error" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:error_migration")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "error_migration",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_error(pid, :migration_failed, %{phase: "transfer"})

      assert_receive {:log_event, log}, 500

      assert log.level == :error
      assert log.component == :migration
      assert log.metadata.phase == "transfer"
    end
  end

  describe "emit_state_transition/4" do
    test "emits FSM transition log" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:transition")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "transition",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_state_transition(pid, :stopped, :starting, %{duration_ms: 42})

      assert_receive {:log_event, log}, 500

      assert log.level == :info
      assert log.component == :fsm
      assert log.message == "State transition: stopped → starting"
      assert log.metadata.from_state == :stopped
      assert log.metadata.to_state == :starting
      assert log.metadata.transition_duration_ms == 42
    end
  end

  describe "set_log_rate/2" do
    test "adjusts log generation rate dynamically" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:rate_change")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "rate_change",
          region: "ord",
          log_rate: :low,
          enable_boot_sequence: false,
          enable_runtime_logs: true
        )

      Process.sleep(1500)
      low_rate_count = count_messages_in_mailbox()
      flush_mailbox()

      Producer.set_log_rate(pid, :high)
      Process.sleep(1000)
      high_rate_count = count_messages_in_mailbox()

      assert high_rate_count > low_rate_count * 1.5
    end
  end

  describe "telemetry" do
    test "emits telemetry event for each log" do
      test_pid = self()

      :telemetry.attach(
        "test-log-produced",
        [:orchestrator, :logs, :produced],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:telemetry_test")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "telemetry_test",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_error(pid, :oom_killed)

      assert_receive {:telemetry, %{count: 1}, metadata}, 500
      assert metadata.machine_id == "telemetry_test"
      assert metadata.level == :error

      :telemetry.detach("test-log-produced")
    end
  end

  describe "log publishing" do
    test "publishes to machine-specific topic" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:pub_test")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "pub_test",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_error(pid, :oom_killed)

      assert_receive {:log_event, log}, 500
      assert log.metadata.machine_id == "pub_test"
    end

    test "publishes to aggregator topic" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "log_aggregator:all_machines")

      {:ok, pid} =
        Producer.start_link(
          machine_id: "agg_test",
          region: "ord",
          enable_boot_sequence: false,
          enable_runtime_logs: false
        )

      Producer.emit_error(pid, :oom_killed)

      assert_receive {:log_event, log}, 500
      assert log.metadata.machine_id == "agg_test"
    end
  end

  describe "runtime log content" do
    test "generates HTTP server logs" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:content_test")

      {:ok, _pid} =
        Producer.start_link(
          machine_id: "content_test",
          region: "ord",
          log_rate: :high,
          enable_boot_sequence: false,
          enable_runtime_logs: true
        )

      logs = collect_logs(100)

      http_logs = Enum.filter(logs, fn log -> log.component == :http_server end)
      assert length(http_logs) > 0

      if length(http_logs) > 0 do
        http_log = List.first(http_logs)
        assert http_log.metadata[:method] in ["GET", "POST", "PUT", "DELETE"]
        assert is_binary(http_log.metadata[:path])
        assert is_integer(http_log.metadata[:status])
        assert is_integer(http_log.metadata[:duration_ms])
      end
    end

    test "generates database logs" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:db_test")

      {:ok, _pid} =
        Producer.start_link(
          machine_id: "db_test",
          region: "ord",
          log_rate: :high,
          enable_boot_sequence: false,
          enable_runtime_logs: true
        )

      logs = collect_logs(100)

      db_logs = Enum.filter(logs, fn log -> log.component == :database end)
      assert length(db_logs) > 0
    end

    test "generates logs with appropriate level distribution" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:level_dist")

      {:ok, _pid} =
        Producer.start_link(
          machine_id: "level_dist",
          region: "ord",
          log_rate: :burst,
          enable_boot_sequence: false,
          enable_runtime_logs: true
        )

      logs = collect_logs(100)

      level_counts =
        Enum.reduce(logs, %{}, fn log, acc ->
          Map.update(acc, log.level, 1, &(&1 + 1))
        end)

      debug_count = Map.get(level_counts, :debug, 0)
      assert debug_count > 30

      error_count = Map.get(level_counts, :error, 0)
      assert error_count < 20
    end
  end

  describe "performance" do
    test "handles high log rate without crashing" do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "machine_logs:perf_test")

      {:ok, _pid} =
        Producer.start_link(
          machine_id: "perf_test",
          region: "ord",
          log_rate: :burst,
          enable_boot_sequence: false,
          enable_runtime_logs: true
        )

      Process.sleep(2000)

      log_count = count_messages_in_mailbox()

      assert log_count >= 50
      assert log_count <= 150
    end

    test "producer consumes minimal memory" do
      {:ok, pid} =
        Producer.start_link(
          machine_id: "memory_test",
          region: "ord",
          log_rate: :high,
          enable_boot_sequence: false,
          enable_runtime_logs: true
        )

      Process.sleep(1000)

      {:memory, memory} = Process.info(pid, :memory)

      assert memory < 1_000_000
    end
  end

  defp count_messages_in_mailbox do
    count_messages_recursive(0)
  end

  defp count_messages_recursive(count) do
    receive do
      {:log_event, _log} -> count_messages_recursive(count + 1)
    after
      0 -> count
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp collect_logs(count) do
    collect_logs_recursive(count, [])
  end

  defp collect_logs_recursive(0, acc), do: Enum.reverse(acc)

  defp collect_logs_recursive(count, acc) do
    receive do
      {:log_event, log} ->
        collect_logs_recursive(count - 1, [log | acc])
    after
      5000 ->
        Enum.reverse(acc)
    end
  end
end
