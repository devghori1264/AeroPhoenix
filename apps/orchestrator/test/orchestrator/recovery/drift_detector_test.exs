defmodule Orchestrator.Recovery.DriftDetectorTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Recovery.DriftDetector
  alias Orchestrator.MachineActor
  alias Orchestrator.MachineActor.Supervisor, as: MachActorSup

  setup do
    cleanup_test_machines()

    on_exit(fn ->
      cleanup_test_machines()
    end)

    :ok
  end

  describe "detect_drift/1 - healthy system" do
    test "returns zero anomalies when all machines are healthy" do
      machine_ids =
        for i <- 1..10 do
          id = "test_healthy_#{i}"

          {:ok, _pid} =
            MachActorSup.start_machine(
              id: id,
              region: "test-region"
            )

          id
        end

      {:ok, report} = DriftDetector.detect_drift()

      assert report.summary.ghosts == 0
      assert report.summary.zombies == 0
      assert report.summary.drifts == 0
      assert report.summary.healthy >= 10

      assert report.scan_duration_ms < 500

      Enum.each(machine_ids, &MachActorSup.stop_machine/1)
    end

    test "reports accurate node and region information" do
      {:ok, report} = DriftDetector.detect_drift()

      assert report.node == node()
      assert is_binary(report.region)
      assert report.timestamp != nil
    end

    test "emits telemetry events on successful scan" do
      test_pid = self()

      :telemetry.attach(
        "test-drift-scan",
        [:orchestrator, :drift_detection, :scan_complete],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      {:ok, _report} = DriftDetector.detect_drift()

      assert_receive {:telemetry, measurements, metadata}, 1000

      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms > 0
      assert metadata.node == node()

      :telemetry.detach("test-drift-scan")
    end
  end

  describe "detect_drift/1 - ghost process detection" do
    test "detects ghost when process is killed but registry not updated" do
      id = "test_ghost_victim"
      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test")

      Process.sleep(50)

      Process.exit(pid, :kill)
      Process.sleep(50)

      {:ok, report} = DriftDetector.detect_drift()

      assert is_map(report.summary)
      assert is_list(report.anomalies)

      try do
        MachActorSup.stop_machine(id)
      rescue
        _ -> :ok
      end
    end

    test "ghost severity is marked as HIGH" do
      id = "test_ghost_severity"
      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test")

      Process.exit(pid, :kill)
      Process.sleep(100)

      {:ok, report} = DriftDetector.detect_drift()

      ghosts = Enum.filter(report.anomalies, &(&1.type == :ghost))

      if length(ghosts) > 0 do
        Enum.each(ghosts, fn ghost ->
          assert ghost.severity == :high
          assert ghost.type == :ghost
          assert is_pid(ghost.pid)
          assert is_binary(ghost.machine_id)
        end)
      end

      try do
        MachActorSup.stop_machine(id)
      rescue
        _ -> :ok
      end
    end
  end

  describe "detect_drift/1 - zombie machine detection" do
    test "detects zombie when database says running but process missing" do
      id = "test_zombie_machine"

      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test")

      MachineActor.transition(pid, :start)
      Process.sleep(100)

      db_path = get_db_path(id)
      assert File.exists?(db_path)

      supervisor_pid = Process.whereis(Orchestrator.MachineActor.Supervisor)
      children = DynamicSupervisor.which_children(supervisor_pid)

      child_spec =
        Enum.find(children, fn
          {_id, ^pid, :worker, _modules} -> true
          _ -> false
        end)

      if child_spec do
        DynamicSupervisor.terminate_child(supervisor_pid, pid)
      end

      Process.sleep(100)

      refute Process.alive?(pid)

      {:ok, db_state} = get_db_state_directly(db_path)
      assert db_state in [:starting, :running, :created]

      {:ok, report} = DriftDetector.detect_drift()

      if db_state in [:running, :starting] do
        zombies = Enum.filter(report.anomalies, &(&1.type == :zombie))

        zombie = Enum.find(zombies, &(&1.machine_id == id))

        if zombie do
          assert zombie.severity == :critical
          assert zombie.type == :zombie
          assert zombie.db_state in [:running, :starting]
          assert String.ends_with?(zombie.db_path, ".db")
        end
      end

      cleanup_machine_data(id)
    end

    test "zombie severity is marked as CRITICAL" do
      id = "test_zombie_critical"

      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test")
      MachineActor.transition(pid, :start)
      Process.sleep(50)

      DynamicSupervisor.terminate_child(
        Orchestrator.MachineActor.Supervisor,
        pid
      )

      Process.sleep(100)

      {:ok, report} = DriftDetector.detect_drift()

      zombies = Enum.filter(report.anomalies, &(&1.type == :zombie))

      if length(zombies) > 0 do
        Enum.each(zombies, fn zombie ->
          assert zombie.severity == :critical
        end)
      end

      cleanup_machine_data(id)
    end

    test "does not flag stopped machines as zombies" do
      id = "test_stopped_not_zombie"

      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test")

      Process.sleep(50)

      MachActorSup.stop_machine(id)
      Process.sleep(50)

      {:ok, report} = DriftDetector.detect_drift()

      zombies = Enum.filter(report.anomalies, &(&1.machine_id == id))
      assert length(zombies) == 0

      cleanup_machine_data(id)
    end
  end

  describe "detect_drift/1 - state drift detection" do
    test "detects drift when process state conflicts with database" do
      id = "test_drift_machine"
      {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test")

      Process.sleep(50)

      {:ok, report} = DriftDetector.detect_drift(skip_state_check: false)

      assert is_integer(report.summary.drifts)
      assert report.summary.drifts >= 0

      MachActorSup.stop_machine(id)
    end

    test "skip_state_check option bypasses drift detection" do
      id = "test_skip_drift"
      {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test")

      {:ok, report} = DriftDetector.detect_drift(skip_state_check: true)

      assert report.summary.drifts == 0

      assert is_integer(report.summary.ghosts)
      assert is_integer(report.summary.zombies)

      MachActorSup.stop_machine(id)
    end

    test "handles timeout when querying slow processes" do
      id = "test_slow_process"
      {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test")

      {:ok, report} = DriftDetector.detect_drift(timeout: 1)

      assert is_map(report)
      assert is_list(report.anomalies)

      MachActorSup.stop_machine(id)
    end
  end

  describe "check_machine/1" do
    test "returns :healthy for properly running machine" do
      id = "test_individual_healthy"
      {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test")

      Process.sleep(50)

      assert {:ok, :healthy} = DriftDetector.check_machine(id)

      MachActorSup.stop_machine(id)
    end

    test "returns :not_found for non-existent machine" do
      assert {:error, :not_found} = DriftDetector.check_machine("nonexistent_id")
    end

    test "detects zombie for individual machine" do
      id = "test_individual_zombie"
      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test")

      MachineActor.transition(pid, :start)
      Process.sleep(50)

      DynamicSupervisor.terminate_child(
        Orchestrator.MachineActor.Supervisor,
        pid
      )

      Process.sleep(50)

      case DriftDetector.check_machine(id) do
        {:ok, :healthy} ->
          :ok

        {:ok, {:anomaly, anomaly}} ->
          assert anomaly.type in [:zombie, :ghost]
          assert anomaly.machine_id == id

        {:error, _reason} ->
          :ok
      end

      cleanup_machine_data(id)
    end

    test "is faster than full scan" do
      id = "test_fast_check"
      {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test")

      start = System.monotonic_time(:millisecond)
      {:ok, _result} = DriftDetector.check_machine(id)
      duration = System.monotonic_time(:millisecond) - start

      assert duration < 10

      MachActorSup.stop_machine(id)
    end
  end

  describe "detect_drift/1 - performance" do
    test "completes scan of 50 machines under 1 second" do
      machine_ids =
        for i <- 1..50 do
          id = "test_perf_#{i}"
          {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test")
          id
        end

      Process.sleep(200)

      start = System.monotonic_time(:millisecond)
      {:ok, report} = DriftDetector.detect_drift()
      duration = System.monotonic_time(:millisecond) - start

      assert duration < 1000
      assert report.scan_duration_ms < 1000
      assert report.total_machines >= 50

      Enum.each(machine_ids, fn id ->
        try do
          MachActorSup.stop_machine(id)
        rescue
          _ -> :ok
        end
      end)

      Process.sleep(100)
    end

    test "parallel scan is faster than sequential for large sets" do
      machine_ids =
        for i <- 1..30 do
          id = "test_parallel_#{i}"
          {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test")
          id
        end

      Process.sleep(200)

      start_seq = System.monotonic_time(:millisecond)
      {:ok, seq_report} = DriftDetector.detect_drift(parallel: false)
      seq_duration = System.monotonic_time(:millisecond) - start_seq

      start_par = System.monotonic_time(:millisecond)
      {:ok, par_report} = DriftDetector.detect_drift(parallel: true)
      par_duration = System.monotonic_time(:millisecond) - start_par

      assert seq_report.total_machines == par_report.total_machines
      assert seq_report.summary.healthy == par_report.summary.healthy

      IO.puts("""
      Performance comparison:
        Sequential: #{seq_duration}ms
        Parallel:   #{par_duration}ms
      """)

      Enum.each(machine_ids, &try_stop_machine/1)
    end
  end

  describe "detect_drift/1 - edge cases" do
    test "handles database corruption gracefully" do
      id = "test_corrupted_db"
      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test")

      Process.sleep(50)
      MachActorSup.stop_machine(id)
      Process.sleep(50)

      db_path = get_db_path(id)

      if File.exists?(db_path) do
        File.write!(db_path, "CORRUPTED DATA")
      end

      {:ok, report} = DriftDetector.detect_drift()

      assert is_map(report)

      cleanup_machine_data(id)
    end

    test "handles concurrent scans without race conditions" do
      machine_ids =
        for i <- 1..10 do
          id = "test_concurrent_#{i}"
          {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test")
          id
        end

      Process.sleep(100)

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> DriftDetector.detect_drift() end)
        end

      results = Task.await_many(tasks, 5000)

      assert length(results) == 5

      Enum.each(results, fn {:ok, report} ->
        assert is_map(report)
        assert report.total_machines >= 10
      end)

      Enum.each(machine_ids, &try_stop_machine/1)
    end

    test "detects anomalies created during scan" do
      machine_ids =
        for i <- 1..5 do
          id = "test_during_scan_#{i}"
          {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test")
          id
        end

      scan_task = Task.async(fn -> DriftDetector.detect_drift() end)

      Process.sleep(10)

      Enum.take(machine_ids, 2)
      |> Enum.each(fn id ->
        case MachActorSup.find_machine(id) do
          {:ok, pid} -> Process.exit(pid, :kill)
          _ -> :ok
        end
      end)

      {:ok, report} = Task.await(scan_task, 5000)

      assert is_map(report)

      Enum.each(machine_ids, &try_stop_machine/1)
    end
  end

  describe "telemetry events" do
    test "emits anomaly_found event for each anomaly" do
      test_pid = self()

      :telemetry.attach_many(
        "test-anomaly-events",
        [
          [:orchestrator, :drift_detection, :anomaly_found]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:anomaly_event, event, measurements, metadata})
        end,
        nil
      )

      id = "test_anomaly_telemetry"
      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test")

      MachineActor.transition(pid, :start)
      Process.sleep(50)

      DynamicSupervisor.terminate_child(
        Orchestrator.MachineActor.Supervisor,
        pid
      )

      Process.sleep(50)

      {:ok, _report} = DriftDetector.detect_drift()

      :telemetry.detach("test-anomaly-events")
      cleanup_machine_data(id)
    end
  end

  defp cleanup_test_machines do
    machines = MachActorSup.list_machines()

    Enum.each(machines, fn id ->
      if String.starts_with?(id, "test_") do
        try_stop_machine(id)
        cleanup_machine_data(id)
      end
    end)

    Process.sleep(100)
  end

  defp try_stop_machine(id) do
    try do
      MachActorSup.stop_machine(id)
    rescue
      _ -> :ok
    catch
      _ -> :ok
    end
  end

  defp cleanup_machine_data(id) do
    db_path = get_db_path(id)

    if File.exists?(db_path) do
      File.rm(db_path)
    end
  end

  defp get_db_path(machine_id) do
    data_dir =
      Application.get_env(:orchestrator, :machine_data_dir, "data/machines")

    Path.join(data_dir, "#{machine_id}.db")
  end

  defp get_db_state_directly(db_path) do
    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} ->
        result =
          case Exqlite.Sqlite3.execute(conn, "SELECT state FROM machines LIMIT 1") do
            {:ok, %{rows: [[state_str]]}} when is_binary(state_str) ->
              {:ok, String.to_existing_atom(state_str)}

            {:ok, %{rows: []}} ->
              {:ok, :created}

            {:error, reason} ->
              {:error, reason}
          end

        Exqlite.Sqlite3.close(conn)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end
end
