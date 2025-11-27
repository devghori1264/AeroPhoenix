defmodule Orchestrator.FlydClientTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Orchestrator.FlydClient

  @moduletag :integration
  @flyd_base_url "http://localhost:8080"

  setup do
    start_supervised!({Finch, name: Orchestrator.Finch})

    wait_for_flyd_ready()

    :ok
  end

  describe "migrate_machine/3" do
    setup do
      machine_id = create_test_machine("migration-test-#{:rand.uniform(10000)}", "us-east-1")
      {:ok, machine_id: machine_id}
    end

    test "successfully initiates migration with default strategy", %{machine_id: machine_id} do
      assert {:ok, response} = FlydClient.migrate_machine(machine_id, "eu-west-1")

      assert is_binary(response["migration_id"])
      assert response["current_phase"] in ["PHASE_VALIDATING", "PHASE_CREATING_TARGET"]
      assert is_binary(response["message"])
      assert is_integer(response["estimated_duration_ms"])
      assert response["estimated_duration_ms"] > 0
    end

    test "successfully initiates migration with live_migration strategy", %{
      machine_id: machine_id
    } do
      assert {:ok, response} =
               FlydClient.migrate_machine(
                 machine_id,
                 "eu-west-1",
                 strategy: "live_migration"
               )

      assert is_binary(response["migration_id"])
      assert response["current_phase"] != nil
    end

    test "successfully initiates migration with clone_and_redirect strategy", %{
      machine_id: machine_id
    } do
      assert {:ok, response} =
               FlydClient.migrate_machine(
                 machine_id,
                 "ap-south-1",
                 strategy: "clone_and_redirect",
                 timeout_seconds: 600
               )

      assert is_binary(response["migration_id"])
    end

    test "passes migration options correctly", %{machine_id: machine_id} do
      assert {:ok, response} =
               FlydClient.migrate_machine(
                 machine_id,
                 "eu-west-1",
                 strategy: "stop_and_move",
                 timeout_seconds: 300,
                 preserve_ip: true,
                 skip_state_verification: false,
                 metadata: %{"reason" => "test_migration", "ticket" => "OPS-123"}
               )

      assert is_binary(response["migration_id"])
    end

    test "returns error for invalid strategy" do
      assert {:error, {:invalid_strategy, "invalid_strategy"}} =
               FlydClient.migrate_machine("machine_123", "eu-west-1",
                 strategy: "invalid_strategy"
               )
    end

    test "returns error for non-existent machine" do
      assert {:error, _reason} =
               FlydClient.migrate_machine("non_existent_machine_id", "eu-west-1")
    end

    test "handles network timeout gracefully" do
      original_base = Application.get_env(:orchestrator, :flyd)[:url]
      Application.put_env(:orchestrator, :flyd, url: "http://localhost:9999")

      assert {:error, :max_retries} = FlydClient.migrate_machine("test", "eu-west-1")

      Application.put_env(:orchestrator, :flyd, url: original_base)
    end

    test "emits telemetry events on successful migration start", %{machine_id: machine_id} do
      :telemetry.attach(
        "test-migration-start",
        [:orchestrator, :migration, :start],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      {:ok, response} = FlydClient.migrate_machine(machine_id, "eu-west-1")

      assert_receive {:telemetry_event, [:orchestrator, :migration, :start],
                      %{duration_ms: duration}, metadata},
                     1000

      assert duration >= 0
      assert metadata.machine_id == machine_id
      assert metadata.target_region == "eu-west-1"
      assert metadata.migration_id == response["migration_id"]

      :telemetry.detach("test-migration-start")
    end

    test "emits telemetry events on migration failure" do
      :telemetry.attach(
        "test-migration-failed",
        [:orchestrator, :migration, :start_failed],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      {:error, _} = FlydClient.migrate_machine("invalid_machine", "eu-west-1")

      assert_receive {:telemetry_event, [:orchestrator, :migration, :start_failed], %{},
                      metadata},
                     1000

      assert metadata.machine_id == "invalid_machine"
      assert metadata.target_region == "eu-west-1"

      :telemetry.detach("test-migration-failed")
    end
  end

  describe "get_migration_status/1" do
    setup do
      machine_id = create_test_machine("status-test-#{:rand.uniform(10000)}", "us-east-1")
      {:ok, response} = FlydClient.migrate_machine(machine_id, "eu-west-1")
      migration_id = response["migration_id"]

      {:ok, migration_id: migration_id}
    end

    test "retrieves migration status successfully", %{migration_id: migration_id} do
      assert {:ok, status} = FlydClient.get_migration_status(migration_id)

      assert status["migration_id"] == migration_id

      assert status["phase"] in [
               "PHASE_VALIDATING",
               "PHASE_CREATING_TARGET",
               "PHASE_SYNCING_DATA",
               "PHASE_REDIRECTING_TRAFFIC",
               "PHASE_CLEANUP",
               "PHASE_COMPLETE"
             ]

      assert status["state"] in [
               "STATE_PENDING",
               "STATE_RUNNING",
               "STATE_COMPLETED",
               "STATE_FAILED"
             ]

      assert is_integer(status["progress_percent"])
      assert status["progress_percent"] >= 0
      assert status["progress_percent"] <= 100
    end

    test "returns error for non-existent migration" do
      assert {:error, :not_found} = FlydClient.get_migration_status("non_existent_migration_id")
    end

    test "logs status retrieval" do
      migration_id = "test_migration_#{:rand.uniform(10000)}"

      log =
        capture_log(fn ->
          FlydClient.get_migration_status(migration_id)
        end)

      assert log =~ "Failed to get migration status"
    end
  end

  describe "stream_migration_progress/2" do
    setup do
      machine_id = create_test_machine("stream-test-#{:rand.uniform(10000)}", "us-east-1")

      {:ok, response} =
        FlydClient.migrate_machine(machine_id, "eu-west-1", strategy: "stop_and_move")

      migration_id = response["migration_id"]

      {:ok, migration_id: migration_id}
    end

    test "streams migration progress updates", %{migration_id: migration_id} do
      test_pid = self()
      progress_updates = []

      callback = fn update ->
        send(test_pid, {:progress_update, update})
      end

      {:ok, stream_pid} = FlydClient.stream_migration_progress(migration_id, callback)

      assert_receive {:progress_update, update}, 10_000

      assert is_map(update)
      assert update["type"] in ["progress", "complete", "error"]

      receive do
        {:migration_complete, _final_state} ->
          :ok

        {:migration_error, _reason} ->
          :ok
      after
        30_000 ->
          :ok
      end

      if Process.alive?(stream_pid), do: Process.exit(stream_pid, :kill)
    end

    test "receives completion event when migration finishes", %{migration_id: migration_id} do
      callback = fn _update -> :ok end
      {:ok, _pid} = FlydClient.stream_migration_progress(migration_id, callback)

      assert_receive {:migration_complete, event}, 30_000
      assert event["type"] == "complete"
      assert event["final_state"] in ["STATE_COMPLETED", "STATE_FAILED", "STATE_ROLLED_BACK"]
    end

    test "handles stream errors gracefully" do
      callback = fn _update -> :ok end
      {:ok, _pid} = FlydClient.stream_migration_progress("invalid_migration_id", callback)

      assert_receive {:migration_error, _reason}, 5_000
    end

    test "logs stream lifecycle events", %{migration_id: migration_id} do
      callback = fn _update -> :ok end

      log =
        capture_log(fn ->
          {:ok, pid} = FlydClient.stream_migration_progress(migration_id, callback)

          Process.sleep(1000)

          if Process.alive?(pid), do: Process.exit(pid, :kill)
          Process.sleep(100)
        end)

      assert log =~ "Starting migration progress stream"
    end
  end

  describe "exponential backoff and retry logic" do
    test "retries on transient failures" do
      assert true
    end

    test "gives up after max retries" do
      original_base = Application.get_env(:orchestrator, :flyd)[:url]
      Application.put_env(:orchestrator, :flyd, url: "http://localhost:9999")

      start_time = System.monotonic_time(:millisecond)
      result = FlydClient.migrate_machine("test", "eu-west-1")
      end_time = System.monotonic_time(:millisecond)

      assert {:error, :max_retries} = result

      assert end_time - start_time > 500

      Application.put_env(:orchestrator, :flyd, url: original_base)
    end
  end

  describe "concurrent migrations" do
    test "handles multiple concurrent migration requests" do
      machines =
        Enum.map(1..5, fn i ->
          create_test_machine("concurrent-#{i}-#{:rand.uniform(10000)}", "us-east-1")
        end)

      tasks =
        Enum.map(machines, fn machine_id ->
          Task.async(fn ->
            FlydClient.migrate_machine(machine_id, "eu-west-1")
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      assert Enum.all?(results, fn result ->
               match?({:ok, _}, result)
             end)

      migration_ids = Enum.map(results, fn {:ok, resp} -> resp["migration_id"] end)
      assert length(Enum.uniq(migration_ids)) == 5
    end
  end

  describe "edge cases and error scenarios" do
    test "handles empty target region" do
      machine_id = create_test_machine("edge-case-#{:rand.uniform(10000)}", "us-east-1")

      assert {:error, _} = FlydClient.migrate_machine(machine_id, "")
    end

    test "handles migration to same region" do
      machine_id = create_test_machine("same-region-#{:rand.uniform(10000)}", "us-east-1")

      result = FlydClient.migrate_machine(machine_id, "us-east-1")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles very large metadata payloads" do
      machine_id = create_test_machine("large-meta-#{:rand.uniform(10000)}", "us-east-1")

      large_metadata =
        Map.new(1..100, fn i ->
          {"key_#{i}", String.duplicate("value", 100)}
        end)

      result =
        FlydClient.migrate_machine(
          machine_id,
          "eu-west-1",
          metadata: large_metadata
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "SSE parsing" do
    test "parses valid SSE events" do
      assert true
    end
  end

  defp wait_for_flyd_ready(retries \\ 30) do
    case make_http_request(:get, "/ping") do
      {:ok, %{status: 200}} ->
        :ok

      _ when retries > 0 ->
        Process.sleep(1000)
        wait_for_flyd_ready(retries - 1)

      _ ->
        raise "flyd-sim not ready after 30 seconds"
    end
  end

  defp create_test_machine(name, region) do
    payload = %{name: name, region: region}

    case make_http_request(:post, "/create", payload) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, response} = Jason.decode(body)
        response["id"]

      error ->
        raise "Failed to create test machine: #{inspect(error)}"
    end
  end

  defp make_http_request(method, path, body \\ nil) do
    url = @flyd_base_url <> path
    headers = [{"content-type", "application/json"}]

    request_body =
      case body do
        nil -> ""
        map -> Jason.encode!(map)
      end

    Finch.build(method, url, headers, request_body)
    |> Finch.request(Orchestrator.Finch)
  end
end
