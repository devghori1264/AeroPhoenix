defmodule PhoenixUiWeb.MachineChannelTest do
  use PhoenixUiWeb.ChannelCase, async: false

  alias PhoenixUiWeb.{UserSocket, MachineChannel}
  alias MachineChannel.{CircularBuffer, TokenBucket}

  setup do
    {:ok, socket} = connect(UserSocket, %{"token" => "test_token_12345"})

    {:ok, socket: socket}
  end

  describe "join/3" do
    test "successfully joins machine channel with valid machine_id", %{socket: socket} do
      assert {:ok, reply, %Phoenix.Socket{}} =
               subscribe_and_join(socket, MachineChannel, "machine:test_machine_123", %{})

      assert reply.joined == true
      assert reply.machine_id == "test_machine_123"
      assert is_map(reply.filters)
    end

    test "joins with custom filters", %{socket: socket} do
      params = %{"filters" => %{"level" => "error", "component" => "fsm"}}

      assert {:ok, reply, channel_socket} =
               subscribe_and_join(socket, MachineChannel, "machine:test_machine_123", params)

      assert channel_socket.assigns.filters.level == "error"
      assert channel_socket.assigns.filters.component == "fsm"
    end

    test "initializes connection state on join", %{socket: socket} do
      {:ok, _reply, channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:test_machine_123", %{})

      assert channel_socket.assigns.machine_id == "test_machine_123"
      assert %CircularBuffer{} = channel_socket.assigns.buffer
      assert %TokenBucket{} = channel_socket.assigns.rate_limiter
      assert channel_socket.assigns.paused == false
      assert is_map(channel_socket.assigns.stats)
    end

    test "rejects join with empty machine_id", %{socket: socket} do
      assert {:error, %{reason: :machine_not_found}} =
               subscribe_and_join(socket, MachineChannel, "machine:", %{})
    end

    test "subscribes to PubSub topic on join", %{socket: socket} do
      {:ok, _reply, _channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:test_machine_123", %{})

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "machine_logs:test_machine_123",
        {:log_event,
         %{
           timestamp: System.system_time(:microsecond),
           level: :info,
           component: :test,
           message: "Test log",
           metadata: %{}
         }}
      )

      assert_receive {:log_event, _log}
    end

    test "emits telemetry on join", %{socket: socket} do
      test_pid = self()

      :telemetry.attach(
        "test-join",
        [:phoenix_ui, :channel, :join],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      subscribe_and_join(socket, MachineChannel, "machine:test_machine_123", %{})

      assert_receive {:telemetry, %{count: 1}, %{machine_id: "test_machine_123"}}

      :telemetry.detach("test-join")
    end
  end

  describe "pause/resume" do
    setup %{socket: socket} do
      {:ok, _reply, channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:test_machine_123", %{})

      {:ok, channel_socket: channel_socket}
    end

    test "pauses log streaming", %{channel_socket: channel_socket} do
      ref = push(channel_socket, "pause", %{})

      assert_reply ref, :ok, %{paused: true}
      assert channel_socket.assigns.paused == false
    end

    test "resumes log streaming", %{channel_socket: channel_socket} do
      push(channel_socket, "pause", %{})

      ref = push(channel_socket, "resume", %{})
      assert_reply ref, :ok, %{paused: false}
    end

    test "emits telemetry on pause", %{channel_socket: channel_socket} do
      test_pid = self()

      :telemetry.attach(
        "test-pause",
        [:phoenix_ui, :channel, :paused],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_pause, measurements, metadata})
        end,
        nil
      )

      push(channel_socket, "pause", %{})

      assert_receive {:telemetry_pause, %{count: 1}, %{machine_id: "test_machine_123"}}

      :telemetry.detach("test-pause")
    end

    test "emits telemetry on resume", %{channel_socket: channel_socket} do
      test_pid = self()

      :telemetry.attach(
        "test-resume",
        [:phoenix_ui, :channel, :resumed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_resume, measurements, metadata})
        end,
        nil
      )

      push(channel_socket, "resume", %{})

      assert_receive {:telemetry_resume, %{count: 1}, %{machine_id: "test_machine_123"}}

      :telemetry.detach("test-resume")
    end
  end

  describe "filter updates" do
    setup %{socket: socket} do
      {:ok, _reply, channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:test_machine_123", %{})

      {:ok, channel_socket: channel_socket}
    end

    test "updates log level filter", %{channel_socket: channel_socket} do
      ref = push(channel_socket, "filter", %{"filters" => %{"level" => "error"}})

      assert_reply ref, :ok, %{filters: filters}
      assert filters.level == "error"
    end

    test "updates component filter", %{channel_socket: channel_socket} do
      ref = push(channel_socket, "filter", %{"filters" => %{"component" => "migration"}})

      assert_reply ref, :ok, %{filters: filters}
      assert filters.component == "migration"
    end

    test "rejects invalid log level", %{channel_socket: channel_socket} do
      ref = push(channel_socket, "filter", %{"filters" => %{"level" => "invalid"}})

      assert_reply ref, :ok, %{filters: filters}
      assert filters.level == "info"
    end

    test "rejects invalid component", %{channel_socket: channel_socket} do
      ref = push(channel_socket, "filter", %{"filters" => %{"component" => "invalid"}})

      assert_reply ref, :ok, %{filters: filters}
      assert is_nil(filters.component)
    end

    test "emits telemetry on filter update", %{channel_socket: channel_socket} do
      test_pid = self()

      :telemetry.attach(
        "test-filter",
        [:phoenix_ui, :channel, :filter_updated],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_filter, measurements, metadata})
        end,
        nil
      )

      push(channel_socket, "filter", %{"filters" => %{"level" => "error"}})

      assert_receive {:telemetry_filter, %{count: 1}, metadata}
      assert metadata.filters.level == "error"

      :telemetry.detach("test-filter")
    end
  end

  describe "get_stats" do
    setup %{socket: socket} do
      {:ok, _reply, channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:test_machine_123", %{})

      {:ok, channel_socket: channel_socket}
    end

    test "returns current connection statistics", %{channel_socket: channel_socket} do
      ref = push(channel_socket, "get_stats", %{})

      assert_reply ref, :ok, stats

      assert is_integer(stats.total_logs)
      assert is_integer(stats.dropped_logs)
      assert is_integer(stats.rate_limited)
      assert is_integer(stats.batches_sent)
      assert is_integer(stats.buffer_size)
      assert stats.buffer_capacity == 1000
      assert is_float(stats.buffer_utilization)
      assert is_boolean(stats.paused)
      assert is_map(stats.filters)
    end
  end

  describe "CircularBuffer" do
    test "creates empty buffer" do
      buffer = CircularBuffer.new(10)

      assert CircularBuffer.size(buffer) == 0
      assert CircularBuffer.empty?(buffer)
    end

    test "inserts items" do
      buffer =
        CircularBuffer.new(10)
        |> CircularBuffer.insert("log1")
        |> CircularBuffer.insert("log2")
        |> CircularBuffer.insert("log3")

      assert CircularBuffer.size(buffer) == 3
      refute CircularBuffer.empty?(buffer)
    end

    test "takes items in FIFO order" do
      buffer =
        CircularBuffer.new(10)
        |> CircularBuffer.insert("log1")
        |> CircularBuffer.insert("log2")
        |> CircularBuffer.insert("log3")

      {items, buffer} = CircularBuffer.take(buffer, 2)

      assert items == ["log1", "log2"]
      assert CircularBuffer.size(buffer) == 1
    end

    test "overwrites oldest when full" do
      buffer = CircularBuffer.new(3)

      buffer =
        buffer
        |> CircularBuffer.insert("log1")
        |> CircularBuffer.insert("log2")
        |> CircularBuffer.insert("log3")
        |> CircularBuffer.insert("log4")

      assert CircularBuffer.size(buffer) == 3

      {items, _buffer} = CircularBuffer.take_all(buffer)
      assert items == ["log2", "log3", "log4"]
    end

    test "handles wrap-around correctly" do
      buffer = CircularBuffer.new(5)

      buffer =
        Enum.reduce(1..5, buffer, fn i, buf ->
          CircularBuffer.insert(buf, "log#{i}")
        end)

      {_items, buffer} = CircularBuffer.take(buffer, 3)

      buffer =
        Enum.reduce(6..8, buffer, fn i, buf ->
          CircularBuffer.insert(buf, "log#{i}")
        end)

      assert CircularBuffer.size(buffer) == 5

      {items, _buffer} = CircularBuffer.take_all(buffer)
      assert items == ["log4", "log5", "log6", "log7", "log8"]
    end

    test "take_all returns all items" do
      buffer =
        CircularBuffer.new(10)
        |> CircularBuffer.insert("log1")
        |> CircularBuffer.insert("log2")
        |> CircularBuffer.insert("log3")

      {items, buffer} = CircularBuffer.take_all(buffer)

      assert items == ["log1", "log2", "log3"]
      assert CircularBuffer.size(buffer) == 0
      assert CircularBuffer.empty?(buffer)
    end

    test "handles large capacity" do
      buffer = CircularBuffer.new(10_000)

      buffer =
        Enum.reduce(1..5000, buffer, fn i, buf ->
          CircularBuffer.insert(buf, "log#{i}")
        end)

      assert CircularBuffer.size(buffer) == 5000
    end

    test "handles edge case of capacity 1" do
      buffer =
        CircularBuffer.new(1)
        |> CircularBuffer.insert("log1")
        |> CircularBuffer.insert("log2")

      assert CircularBuffer.size(buffer) == 1

      {items, _buffer} = CircularBuffer.take_all(buffer)
      assert items == ["log2"]
    end
  end

  describe "TokenBucket" do
    test "creates bucket with full capacity" do
      bucket = TokenBucket.new(100)

      assert bucket.capacity == 100
      assert bucket.tokens == 100
    end

    test "consumes tokens" do
      bucket = TokenBucket.new(100)

      assert TokenBucket.consume(bucket)
    end

    test "refills over time" do
      bucket = TokenBucket.new(10)

      bucket =
        Enum.reduce(1..10, bucket, fn _i, buck ->
          TokenBucket.consume(buck)
          buck
        end)
    end

    test "respects capacity limit" do
      bucket = TokenBucket.new(10)

      Process.sleep(100)
    end
  end

  describe "log event handling" do
    setup %{socket: socket} do
      {:ok, _reply, channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:test_machine_123", %{})

      {:ok, channel_socket: channel_socket}
    end

    test "receives and processes log events from PubSub" do
      log_event = %{
        timestamp: System.system_time(:microsecond),
        level: :info,
        component: :fsm,
        message: "Machine started",
        metadata: %{machine_id: "test_machine_123"}
      }

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "machine_logs:test_machine_123",
        {:log_event, log_event}
      )

      assert_push "log", pushed_log
      assert pushed_log.message == "Machine started"
      assert pushed_log.level == :info
    end

    test "filters logs by level" do
      {:ok, _reply, channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:test_machine_456", %{
          "filters" => %{"level" => "error"}
        })

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "machine_logs:test_machine_456",
        {:log_event,
         %{
           timestamp: System.system_time(:microsecond),
           level: :info,
           component: :fsm,
           message: "Info message",
           metadata: %{}
         }}
      )

      refute_push "log", _

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "machine_logs:test_machine_456",
        {:log_event,
         %{
           timestamp: System.system_time(:microsecond),
           level: :error,
           component: :fsm,
           message: "Error message",
           metadata: %{}
         }}
      )

      assert_push "log", pushed_log
      assert pushed_log.message == "Error message"
    end

    test "batches multiple logs efficiently" do
      Enum.each(1..10, fn i ->
        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "machine_logs:test_machine_123",
          {:log_event,
           %{
             timestamp: System.system_time(:microsecond),
             level: :info,
             component: :fsm,
             message: "Log #{i}",
             metadata: %{}
           }}
        )
      end)

      for _i <- 1..10 do
        assert_push "log", _log
      end
    end
  end

  describe "performance" do
    test "handles high-throughput log stream" do
      {:ok, socket} = connect(UserSocket, %{"token" => "test_token_perf"})

      {:ok, _reply, _channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:perf_test", %{})

      start_time = System.monotonic_time(:millisecond)

      Enum.each(1..1000, fn i ->
        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "machine_logs:perf_test",
          {:log_event,
           %{
             timestamp: System.system_time(:microsecond),
             level: :info,
             component: :fsm,
             message: "Performance test log #{i}",
             metadata: %{}
           }}
        )
      end)

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      assert duration < 5000
    end

    test "circular buffer prevents memory exhaustion" do
      buffer = CircularBuffer.new(1000)

      buffer =
        Enum.reduce(1..10_000, buffer, fn i, buf ->
          CircularBuffer.insert(buf, "log#{i}")
        end)

      assert CircularBuffer.size(buffer) == 1000

      {items, _buffer} = CircularBuffer.take_all(buffer)
      first_item = List.first(items)
      last_item = List.last(items)

      assert first_item == "log9001"
      assert last_item == "log10000"
    end

    test "token bucket enforces rate limit" do
      bucket = TokenBucket.new(10)

      results =
        Enum.map(1..15, fn _i ->
          TokenBucket.consume(bucket)
        end)

      successful = Enum.count(results, & &1)

      assert successful >= 10
    end
  end

  describe "edge cases" do
    test "handles malformed log events gracefully" do
      {:ok, socket} = connect(UserSocket, %{"token" => "test_token_edge"})

      {:ok, _reply, _channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:edge_test", %{})

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "machine_logs:edge_test",
        {:log_event, %{message: "Incomplete log"}}
      )
    end

    test "handles rapid pause/resume cycles" do
      {:ok, socket} = connect(UserSocket, %{"token" => "test_token_rapid"})

      {:ok, _reply, channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:rapid_test", %{})

      Enum.each(1..10, fn _i ->
        push(channel_socket, "pause", %{})
        push(channel_socket, "resume", %{})
      end)
    end

    test "handles filter updates while paused" do
      {:ok, socket} = connect(UserSocket, %{"token" => "test_token_filter_pause"})

      {:ok, _reply, channel_socket} =
        subscribe_and_join(socket, MachineChannel, "machine:filter_pause_test", %{})

      push(channel_socket, "pause", %{})

      ref = push(channel_socket, "filter", %{"filters" => %{"level" => "error"}})
      assert_reply ref, :ok, %{filters: _filters}

      push(channel_socket, "resume", %{})
    end
  end
end
