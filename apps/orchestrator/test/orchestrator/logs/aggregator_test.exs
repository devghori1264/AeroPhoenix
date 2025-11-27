defmodule Orchestrator.Logs.AggregatorTest do
  use ExUnit.Case, async: false
  alias Orchestrator.Logs.Aggregator

  setup do
    {:ok, pid} = Aggregator.start_link([])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, aggregator: pid}
  end

  describe "start_link/1" do
    test "starts aggregator GenServer" do
      {:ok, pid} = Aggregator.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "subscribes to PubSub on start" do
      log = sample_log("test_machine")

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, log}
      )

      Process.sleep(50)

      logs = Aggregator.get_recent_logs(10)
      assert length(logs) > 0
    end
  end

  describe "log ingestion" do
    test "receives logs from PubSub", %{aggregator: _pid} do
      log = sample_log("ingest_test")

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, log}
      )

      Process.sleep(50)

      logs = Aggregator.get_recent_logs(10)
      assert Enum.any?(logs, fn l -> l.metadata.machine_id == "ingest_test" end)
    end

    test "buffers logs in memory", %{aggregator: _pid} do
      Enum.each(1..10, fn i ->
        log = sample_log("buffer_test_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(50)

      logs = Aggregator.get_recent_logs(20)
      assert length(logs) == 10
    end

    test "updates statistics on log ingestion", %{aggregator: _pid} do
      initial_stats = Aggregator.stats()

      Enum.each(1..5, fn i ->
        log = sample_log("stats_test_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(50)

      stats = Aggregator.stats()
      assert stats.total_logs_received == initial_stats.total_logs_received + 5
    end

    test "handles high-throughput ingestion", %{aggregator: _pid} do
      start_time = System.monotonic_time(:millisecond)

      Enum.each(1..1000, fn i ->
        log = sample_log("throughput_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      assert duration < 2000

      Process.sleep(200)

      stats = Aggregator.stats()
      assert stats.total_logs_received >= 1000
    end
  end

  describe "buffer management" do
    test "enforces buffer capacity limit", %{aggregator: _pid} do
      GenServer.stop(Aggregator)
      {:ok, _pid} = Aggregator.start_link(buffer_size: 100)

      Enum.each(1..150, fn i ->
        log = sample_log("capacity_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(100)

      stats = Aggregator.stats()

      assert stats.buffer_size <= 100

      assert stats.total_logs_dropped > 0
    end

    test "drops oldest logs when buffer is full", %{aggregator: _pid} do
      GenServer.stop(Aggregator)
      {:ok, _pid} = Aggregator.start_link(buffer_size: 10)

      Enum.each(1..20, fn i ->
        log = sample_log("oldest_#{i}", "Log number #{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )

        Process.sleep(10)
      end)

      Process.sleep(100)

      logs = Aggregator.get_recent_logs(20)

      assert length(logs) <= 10

      if length(logs) > 0 do
        first_log = List.first(logs)
        assert first_log.message =~ ~r/Log number (1[0-9]|20)/
      end
    end

    test "emits telemetry when logs are dropped", %{aggregator: _pid} do
      GenServer.stop(Aggregator)
      {:ok, _pid} = Aggregator.start_link(buffer_size: 5)

      test_pid = self()

      :telemetry.attach(
        "test-log-dropped",
        [:orchestrator, :logs, :dropped],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_dropped, measurements, metadata})
        end,
        nil
      )

      Enum.each(1..10, fn i ->
        log = sample_log("drop_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      assert_receive {:telemetry_dropped, %{count: 1}, %{reason: :buffer_full}}, 1000

      :telemetry.detach("test-log-dropped")
    end
  end

  describe "batch processing" do
    test "writes batches to storage periodically", %{aggregator: _pid} do
      test_pid = self()

      :telemetry.attach(
        "test-batch-written",
        [:orchestrator, :logs, :batch_written],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:batch_written, measurements, metadata})
        end,
        nil
      )

      Enum.each(1..10, fn i ->
        log = sample_log("batch_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      assert_receive {:batch_written, measurements, metadata}, 500

      assert measurements.count > 0
      assert measurements.bytes > 0
      assert metadata.compression_ratio > 0

      :telemetry.detach("test-batch-written")
    end

    test "compresses batches for storage", %{aggregator: _pid} do
      test_pid = self()

      :telemetry.attach(
        "test-compression",
        [:orchestrator, :logs, :batch_written],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:compression, measurements, metadata})
        end,
        nil
      )

      Enum.each(1..50, fn _i ->
        log = sample_log("compress_test", "Repeating log message for compression test")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      assert_receive {:compression, _measurements, metadata}, 500

      assert metadata.compression_ratio > 1.0

      :telemetry.detach("test-compression")
    end

    test "flushes buffer on demand", %{aggregator: _pid} do
      Enum.each(1..5, fn i ->
        log = sample_log("flush_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(50)

      initial_stats = Aggregator.stats()

      :ok = Aggregator.flush()

      stats = Aggregator.stats()

      assert stats.total_logs_stored > initial_stats.total_logs_stored
    end
  end

  describe "get_recent_logs/2" do
    test "returns recent logs", %{aggregator: _pid} do
      Enum.each(1..10, fn i ->
        log = sample_log("recent_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(50)

      logs = Aggregator.get_recent_logs(10)
      assert length(logs) == 10
    end

    test "respects limit parameter", %{aggregator: _pid} do
      Enum.each(1..20, fn i ->
        log = sample_log("limit_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(50)

      logs = Aggregator.get_recent_logs(5)
      assert length(logs) == 5
    end

    test "returns most recent logs first", %{aggregator: _pid} do
      Enum.each(1..5, fn i ->
        log = sample_log("order_test", "Log #{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )

        Process.sleep(10)
      end)

      Process.sleep(50)

      logs = Aggregator.get_recent_logs(5)

      first_log = List.first(logs)
      assert first_log.message == "Log 5"
    end

    test "filters by log level", %{aggregator: _pid} do
      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, sample_log("filter1", "Info log", :info)}
      )

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, sample_log("filter2", "Error log", :error)}
      )

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, sample_log("filter3", "Debug log", :debug)}
      )

      Process.sleep(50)

      error_logs = Aggregator.get_recent_logs(10, level: :error)

      assert length(error_logs) == 1
      assert List.first(error_logs).level == :error
    end

    test "filters by component", %{aggregator: _pid} do
      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, sample_log_with_component("comp1", :fsm)}
      )

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, sample_log_with_component("comp2", :network)}
      )

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, sample_log_with_component("comp3", :fsm)}
      )

      Process.sleep(50)

      fsm_logs = Aggregator.get_recent_logs(10, component: :fsm)

      assert length(fsm_logs) == 2
      assert Enum.all?(fsm_logs, fn log -> log.component == :fsm end)
    end

    test "filters by timestamp", %{aggregator: _pid} do
      old_timestamp = System.system_time(:microsecond) - 1_000_000

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, sample_log_with_timestamp("old", old_timestamp)}
      )

      Process.sleep(50)

      new_timestamp = System.system_time(:microsecond)

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "log_aggregator:all_machines",
        {:log_event, sample_log_with_timestamp("new", new_timestamp)}
      )

      Process.sleep(50)

      recent_logs = Aggregator.get_recent_logs(10, since: new_timestamp - 100_000)

      assert length(recent_logs) == 1
      assert List.first(recent_logs).metadata.machine_id == "new"
    end
  end

  describe "get_machine_logs/2" do
    test "returns logs for specific machine", %{aggregator: _pid} do
      Enum.each(1..5, fn i ->
        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, sample_log("machine_a")}
        )

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, sample_log("machine_b")}
        )
      end)

      Process.sleep(50)

      machine_a_logs = Aggregator.get_machine_logs("machine_a")

      assert length(machine_a_logs) == 5

      assert Enum.all?(machine_a_logs, fn log ->
               log.metadata.machine_id == "machine_a"
             end)
    end

    test "respects limit option", %{aggregator: _pid} do
      Enum.each(1..10, fn _i ->
        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, sample_log("limit_machine")}
        )
      end)

      Process.sleep(50)

      logs = Aggregator.get_machine_logs("limit_machine", limit: 3)

      assert length(logs) == 3
    end
  end

  describe "stats/0" do
    test "returns comprehensive statistics", %{aggregator: _pid} do
      stats = Aggregator.stats()

      assert is_integer(stats.total_logs_received)
      assert is_integer(stats.total_logs_stored)
      assert is_integer(stats.total_logs_dropped)
      assert is_integer(stats.buffer_size)
      assert is_integer(stats.buffer_capacity)
      assert is_float(stats.buffer_utilization)
      assert is_integer(stats.batches_written)
      assert is_float(stats.compression_ratio)
      assert is_float(stats.avg_batch_size)
      assert is_integer(stats.bytes_received)
      assert is_integer(stats.bytes_stored)
      assert is_integer(stats.uptime_seconds)
      assert is_float(stats.logs_per_second)
    end

    test "tracks buffer utilization", %{aggregator: _pid} do
      GenServer.stop(Aggregator)
      {:ok, _pid} = Aggregator.start_link(buffer_size: 100)

      Enum.each(1..50, fn i ->
        log = sample_log("util_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(50)

      stats = Aggregator.stats()

      assert stats.buffer_utilization >= 0.4
      assert stats.buffer_utilization <= 0.6
    end

    test "calculates logs per second", %{aggregator: _pid} do
      Enum.each(1..10, fn i ->
        log = sample_log("rate_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(100)

      stats = Aggregator.stats()

      assert stats.logs_per_second > 0
    end

    test "tracks compression ratio", %{aggregator: _pid} do
      Enum.each(1..50, fn i ->
        log = sample_log("compress_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(200)

      stats = Aggregator.stats()

      if stats.batches_written > 0 do
        assert stats.compression_ratio > 0
      end
    end
  end

  describe "performance" do
    test "handles 10,000 logs efficiently", %{aggregator: _pid} do
      start_time = System.monotonic_time(:millisecond)

      Enum.each(1..10_000, fn i ->
        log = sample_log("perf_#{rem(i, 100)}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      assert duration < 5000

      Process.sleep(500)

      stats = Aggregator.stats()
      assert stats.total_logs_received >= 10_000
    end

    test "maintains low memory footprint", %{aggregator: pid} do
      Enum.each(1..1000, fn i ->
        log = sample_log("mem_#{i}")

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "log_aggregator:all_machines",
          {:log_event, log}
        )
      end)

      Process.sleep(200)

      {:memory, memory} = Process.info(pid, :memory)

      assert memory < 50_000_000
    end
  end

  defp sample_log(machine_id, message \\ "Test log", level \\ :info) do
    %{
      timestamp: System.system_time(:microsecond),
      level: level,
      component: :test,
      message: message,
      metadata: %{
        machine_id: machine_id,
        region: "ord",
        node: Node.self()
      }
    }
  end

  defp sample_log_with_component(machine_id, component) do
    %{
      timestamp: System.system_time(:microsecond),
      level: :info,
      component: component,
      message: "Test log",
      metadata: %{
        machine_id: machine_id,
        region: "ord"
      }
    }
  end

  defp sample_log_with_timestamp(machine_id, timestamp) do
    %{
      timestamp: timestamp,
      level: :info,
      component: :test,
      message: "Test log",
      metadata: %{
        machine_id: machine_id,
        region: "ord"
      }
    }
  end
end
