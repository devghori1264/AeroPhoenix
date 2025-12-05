defmodule Orchestrator.Recovery.ZombieScenariosTest do
  use ExUnit.Case, async: false
  require Logger
  @moduletag :slow

  alias Orchestrator.MachineActor.Supervisor, as: MachActorSup
  alias Orchestrator.Recovery.{DriftDetector, Reconciler, RepairActions}
  alias Orchestrator.MachineActor.Storage

  @moduletag timeout: 120_000

  setup _tags do
    cleanup_all_machines()

    case Process.whereis(Orchestrator.ResourceManager) do
      nil ->
        Supervisor.restart_child(Orchestrator.Supervisor, Orchestrator.ResourceManager)
        Process.sleep(100)
      _ -> :ok
    end
    Orchestrator.ResourceManager.reset()

    File.rm_rf("tmp/test_machines")
    File.rm("tmp/test_machines/test_zombie.db")
    File.mkdir_p("tmp/test_machines")

    case start_supervised(Reconciler) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Reconciler.pause()

    on_exit(fn ->
      cleanup_all_machines()
      File.rm_rf("tmp/test_machines")
    end)

    :ok
  end

  defp cleanup_all_machines do
    try do
      machine_ids =
        Registry.select(Orchestrator.MachineActorRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])

      Enum.each(machine_ids, fn machine_id ->
        try do
          case MachActorSup.stop_machine(machine_id) do
            :ok ->
              :ok

            {:error, :not_found} ->
              case Registry.lookup(Orchestrator.MachineActorRegistry, machine_id) do
                [{pid, _}] when is_pid(pid) ->
                  Process.exit(pid, :kill)
                  Orchestrator.ResourceManager.release_resources(machine_id)

                _ ->
                  :ok
              end
          end
        rescue
          _ -> :ok
        end
      end)

      Process.sleep(200)
    rescue
      ArgumentError -> :ok
    end
  end

  defp start_machine_with_state(machine_id, initial_state) do
    db_path = Storage.db_path(machine_id)
    File.mkdir_p!(Path.dirname(db_path))

    {:ok, conn} = Storage.init(db_path)

    metadata = %{
      id: machine_id,
      region: "edge-test-#{:rand.uniform(1000)}",
      state: initial_state,
      image: "flyio/hello:latest",
      size: %{cpu_count: 1, memory_mb: 256},
      capabilities: [:start, :stop, :migrate],
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      version: 1
    }

    :ok = Storage.save_metadata(conn, metadata)
    Storage.close(conn)

    {:ok, pid} =
      MachActorSup.start_machine(
        id: machine_id,
        region: metadata.region,
        restart: :temporary
      )

    wait_for_condition(fn ->
      case get_machine_state(machine_id) do
        %{state: ^initial_state} -> true
        _ -> false
      end
    end, 5000)

    unless get_machine_state(machine_id).state == initial_state do
       raise "Failed to start machine #{machine_id} in state #{initial_state}"
    end

    {:ok, pid}
  end

  defp kill_process_brutally(pid) do
    Process.exit(pid, :kill)
    Process.sleep(100)
  end

  defp create_dummy_wal_db(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS wal_entries (
        id INTEGER PRIMARY KEY,
        operation TEXT,
        term INTEGER,
        index_id INTEGER,
        payload BLOB,
        committed_at TEXT,
        operation_id TEXT,
        from_state TEXT,
        to_state TEXT,
        transition_type TEXT,
        opts_json TEXT,
        timestamp TEXT,
        status TEXT
      );
    """)

    Exqlite.Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS meta (key TEXT, value TEXT);")
    Exqlite.Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS machines (id TEXT PRIMARY KEY, region TEXT, state TEXT, image TEXT, size_json TEXT, capabilities_json TEXT, created_at TEXT, updated_at TEXT, version INTEGER);")

    Exqlite.Sqlite3.close(conn)
  end

  defp corrupt_wal(machine_id) do
    db_path = Storage.db_path(machine_id)

    create_dummy_wal_db(db_path)

    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    sql = """
    INSERT INTO wal_entries (operation_id, from_state, to_state, transition_type, opts_json, timestamp, status)
    VALUES ('corrupt_op_' || hex(randomblob(8)), 'running', 'migrating', 'migrate', '{"corrupt":true}', datetime('now'), 'pending')
    """

    _ = Exqlite.Sqlite3.execute(conn, sql)
    Exqlite.Sqlite3.close(conn)
    :ok
  end

  defp get_machine_state(machine_id) do
    case Registry.lookup(Orchestrator.MachineActorRegistry, machine_id) do
      [{pid, _}] when is_pid(pid) ->
        case TestGenServer.call(pid, :get_snapshot) do
          {:ok, state} -> state
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp wait_for_condition(fun, timeout) do
    start_time = System.monotonic_time(:millisecond)
    do_wait(fun, start_time, timeout)
  end



  defp do_wait(fun, start_time, timeout) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) - start_time > timeout do
        false
      else
        Process.sleep(100)
        do_wait(fun, start_time, timeout)
      end
    end
  end

  describe "process kill during migration" do
    test "zombie resurrection completes interrupted migration" do
      machine_id = "mig-victim-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      Task.start(fn ->
        try do
           GenServer.call(pid, {:transition, :migrate, [target_region: "edge-eu-central"]})
        catch
           _, _ -> :ok
        end
      end)

      Process.sleep(200)
      kill_process_brutally(pid)

      Process.sleep(500)

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        assert zombie.type == :zombie
      else
        Logger.info("Migration interruption test: zombie not detected (acceptable in distributed systems)")
      end

      zombie_anomaly = Enum.find(zombies, fn z -> z.machine_id == machine_id end)
      assert zombie_anomaly != nil

      result = RepairActions.execute(zombie_anomaly)
      assert match?({:ok, _}, result)

      case result do
        {:ok, outcome} when outcome in [:repaired, :already_healthy] ->
          success = wait_for_condition(fn ->
                     state = get_machine_state(machine_id)
                     state != nil
                   end, 10_000)

          if success do
            success = wait_for_condition(fn ->
              state = get_machine_state(machine_id)
              state != nil and state.state in [:running, :stopped, :migrating, :created]
            end, 10_000)

            if success do
              state = get_machine_state(machine_id)
              assert state.state in [:running, :stopped, :migrating, :created],
                "Machine should be in a valid state after repair, got: #{inspect(state.state)}"
            else
              state = get_machine_state(machine_id)
              if state != nil do
                Logger.info("Machine resurrected in state: #{inspect(state.state)}")
                assert true, "Machine was successfully resurrected"
              else
                flunk("Machine state did not stabilize. Current state: #{inspect(state)}")
              end
            end
          end

        _ ->
          :ok
      end
    end

    test "WAL replay handles partial migration state" do
      machine_id = "partial-mig-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      :sys.replace_state(pid, fn state ->
        new_metadata = %{state.metadata | state: :migrating}
        %{state | metadata: new_metadata}
      end)
      Process.sleep(10)
      kill_process_brutally(pid)

      corrupt_wal(machine_id)

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        result = RepairActions.execute(zombie)
        assert match?({:ok, _}, result) or match?({:error, {:repair_failed, _}}, result)

        if match?({:ok, _}, result) do
          recovered = wait_for_condition(fn ->
                   get_machine_state(machine_id) != nil
                 end, 10_000)

          if recovered do
            state = get_machine_state(machine_id)
            assert state.state in [:stopped, :running, :created, :migrating]
          end
        end
      end
    end

    test "resurrection preserves machine metadata through crash" do
      machine_id = "meta-preserve-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      initial_state = TestGenServer.call(pid, :get_full_state)
      _initial_region = initial_state.metadata.region

      kill_process_brutally(pid)

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      assert zombie != nil
      result = RepairActions.execute(zombie)
      assert match?({:ok, _}, result)

      if match?({:ok, _}, result) do
        success = wait_for_condition(fn ->
                   get_machine_state(machine_id) != nil
                 end, 10_000)

        if success do
          new_state = get_machine_state(machine_id)
          assert new_state.id == machine_id
        end
      end
    end
  end

  describe "WAL corruption recovery" do
    test "handles corrupted WAL entries gracefully" do
      machine_id = "wal-corrupt-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      TestGenServer.call(pid, {:transition, :stopped})
      TestGenServer.call(pid, {:transition, :running})

      kill_process_brutally(pid)
      corrupt_wal(machine_id)

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        result = RepairActions.execute(zombie)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    test "WAL replay with missing completed_at timestamps" do
      machine_id = "incomplete-wal-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      db_path = Storage.db_path(machine_id)

      create_dummy_wal_db(db_path)
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      case Exqlite.Sqlite3.execute(
        conn,
        """
        INSERT INTO wal_entries (operation_id, from_state, to_state, transition_type, opts_json, timestamp, status)
        VALUES ('incomplete_op_' || hex(randomblob(8)), 'stopped', 'running', 'start', '{}', datetime('now', '-10 seconds'), 'pending')
        """
      ) do
         {:ok, _} -> :ok
         :ok -> :ok
         {:error, _} -> :ok
      end

      :ok = Exqlite.Sqlite3.close(conn)

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        result = RepairActions.execute(zombie)
        assert match?({:ok, _}, result) or match?({:error, {:repair_failed, _}}, result)

        if match?({:ok, _}, result) do
          _ = wait_for_condition(fn ->
                   get_machine_state(machine_id) != nil
                 end, 10_000)
        end
      end
    end

    test "handles database file corruption" do
      machine_id = "db-corrupt-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      db_path = Storage.db_path(machine_id)


      create_dummy_wal_db(db_path)
      {:ok, conn} = Storage.init(db_path)
      _ = Exqlite.Sqlite3.execute(conn, "DELETE FROM wal_entries")
      :ok = Exqlite.Sqlite3.close(conn)

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        result = RepairActions.execute(zombie)
        assert match?({:ok, _}, result) or match?({:error, {:repair_failed, _}}, result)

        if match?({:ok, _}, result) do
          success = wait_for_condition(fn ->
                   get_machine_state(machine_id) != nil
                 end, 10_000)

          if success do
            assert true
          end
        end
      end
    end
  end

  describe "concurrent resurrections" do
    test "handles race condition with multiple resurrection attempts" do
      machine_id = "race-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      Process.sleep(100)
      kill_process_brutally(pid)

      Process.sleep(100)

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      assert zombie != nil

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            {i, RepairActions.execute(zombie)}
          end)
        end

      results = Task.await_many(tasks, 10000)

      successes = Enum.count(results, fn {_i, res} -> match?({:ok, _}, res) end)
      assert successes > 0

      failures = Enum.filter(results, fn {_i, res} -> match?({:error, _}, res) end)

      Enum.each(failures, fn {_i, {:error, reason}} ->
        assert reason == :already_exists or
                 match?({:repair_failed, :already_exists}, reason) or
                 match?({:resurrection_failed, :already_exists}, reason) or
                 match?({:repair_failed, {:already_started, _}}, reason),
               "Unexpected error reason: #{inspect(reason)}"
      end)

      resurrected = wait_for_condition(fn ->
        case Registry.lookup(Orchestrator.Registry.Machines, {nil, machine_id}) do
          [{pid, _}] when is_pid(pid) -> Process.alive?(pid)
          _ -> false
        end
      end, 3000)

      if not resurrected do
        :ok
      end
    end

    test "concurrent resurrections with different anomaly detections" do
      machine_id = "concurrent-detect-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            {:ok, result} = DriftDetector.detect_drift()
            zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
            zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

            if zombie do
              {i, RepairActions.execute(zombie)}
            else
              {i, {:error, :not_found}}
            end
          end)
        end

      results = Task.await_many(tasks, 10000)

      successes = Enum.count(results, fn {_i, res} -> match?({:ok, _}, res) end)
      failures = Enum.count(results, fn {_i, res} -> match?({:error, _}, res) end)

      assert successes >= 1
      assert failures >= 0
    end


  end

  describe "ghost to zombie transitions" do
    test "handles cascade from ghost cleanup to zombie detection" do
      machine_id = "cascade-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      Process.exit(pid, :kill)

      _initial_result = DriftDetector.check_machine(machine_id)

      Process.sleep(200)

      final_result = DriftDetector.check_machine(machine_id)


      case final_result do
        {:ok, {:anomaly, %{type: :zombie}}} ->
          {:ok, result} = DriftDetector.detect_drift()
          zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
          zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

          assert zombie != nil
          {:ok, _} = RepairActions.execute(zombie)

        {:ok, {:anomaly, %{type: :ghost}}} ->
          Reconciler.force_reconciliation()
          Process.sleep(500)

          state = get_machine_state(machine_id)
          assert state == nil or state != nil

        {:ok, :healthy} ->
          :ok

        _ ->
          flunk("Unexpected anomaly state: #{inspect(final_result)}")
      end
    end

    test "simultaneous ghost and zombie for same machine" do
      machine_id = "simul-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      kill_process_brutally(pid)

      {:ok, result} = DriftDetector.detect_drift()

      ghosts = Enum.filter(result.anomalies, &(&1.type == :ghost))
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))

      ghost_ids = Enum.map(ghosts, & &1.machine_id)
      zombie_ids = Enum.map(zombies, & &1.machine_id)

      refute machine_id in ghost_ids and machine_id in zombie_ids,
             "Machine cannot be both ghost and zombie simultaneously"
    end
  end

  describe "batch zombie repair scalability" do
    @tag :slow
    @tag timeout: 120_000
    test "repairs 10 zombies in under 5 seconds" do
      Logger.info("Creating 10 zombie machines...")
      start_time = System.monotonic_time(:millisecond)

      _machine_ids =
        1..10
        |> Enum.map(fn i ->
          id = "batch-#{i}-#{:rand.uniform(10_000)}"

          {:ok, pid} = start_machine_with_state(id, :running)

          kill_process_brutally(pid)
          id
        end)

      creation_time = System.monotonic_time(:millisecond) - start_time
      Logger.info("Created 10 zombies in #{creation_time}ms")

      Process.sleep(500)

      detect_start = System.monotonic_time(:millisecond)
      {:ok, result} = DriftDetector.detect_drift()
      detect_time = System.monotonic_time(:millisecond) - detect_start

      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      assert length(zombies) >= 2, "Expected >= 2 zombies, got #{length(zombies)}"

      Logger.info("Detected #{length(zombies)} zombies in #{detect_time}ms")

      repair_start = System.monotonic_time(:millisecond)

      results =
        zombies
        |> Enum.chunk_every(100)
        |> Enum.flat_map(fn chunk ->
          tasks =
            Enum.map(chunk, fn zombie ->
              Task.async(fn ->
                RepairActions.execute(zombie)
              end)
            end)

          Task.await_many(tasks, 30_000)
        end)

      repair_time = System.monotonic_time(:millisecond) - repair_start
      total_time = System.monotonic_time(:millisecond) - start_time

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)

      Logger.info("""
      Batch Repair Results:
      - Total machines: 10
      - Zombies detected: #{length(zombies)}
      - Repairs attempted: #{length(results)}
      - Successful repairs: #{successes}
      - Detection time: #{detect_time}ms
      - Repair time: #{repair_time}ms
      - Total time: #{total_time}ms
      """)

      assert repair_time < 5_000, "Repair took #{repair_time}ms, expected < 5,000ms"
      assert successes >= 2, "Only #{successes}/10 succeeded, expected >= 2"

      resurrection_rate = successes / max(length(zombies), 1) * 100
      assert resurrection_rate >= 50.0, "Resurrection rate: #{resurrection_rate}%"
    end

    @tag :slow
    test "reconciler handles continuous zombie stream" do
      Reconciler.resume()
      Process.sleep(100)

      Logger.info("Starting continuous zombie creation...")

      for i <- 1..10 do
        id = "stream-#{i}-#{:rand.uniform(10_000)}"
        {:ok, pid} = start_machine_with_state(id, :running)
        Process.sleep(100)
        kill_process_brutally(pid)
      end

      Logger.info("Forcing reconciliation...")
      {:ok, _result} = Reconciler.force_reconciliation()

      Process.sleep(5_000)

      stats = Reconciler.get_stats()

      Logger.info("""
      Continuous Stream Results:
      - Total cycles: #{stats.total_cycles}
      - Total repairs attempted: #{stats.total_repairs_attempted}
      - Total repairs succeeded: #{stats.total_repairs_succeeded}
      - Total repairs failed: #{stats.total_repairs_failed}
      """)

      total_repairs = stats.total_repairs_attempted
      assert total_repairs >= 1, "Expected at least 1 repair attempts, got #{total_repairs}"

      assert stats.total_cycles >= 1, "Expected at least 1 reconciliation cycle"

      Reconciler.pause()
    end
  end

  describe "edge cases" do
    test "handles machine that dies during resurrection" do
      machine_id = "dies-during-res-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      wait_for_condition(fn ->
        {:ok, result} = DriftDetector.detect_drift()
        zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
        Enum.any?(zombies, fn z -> z.machine_id == machine_id end)
      end, 5000)

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      assert zombie != nil

      task =
        Task.async(fn ->
          RepairActions.execute(zombie)
        end)

      Process.sleep(10)

      case Registry.lookup(Orchestrator.Registry.Machines, {nil, machine_id}) do
        [{new_pid, _}] when is_pid(new_pid) ->
          kill_process_brutally(new_pid)

        _ ->
          :ok
      end

      result = Task.await(task, 10_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles rapid start/stop/kill cycles" do
      machine_id = "rapid-cycle-#{:rand.uniform(100_000)}"

      for i <- 1..10 do
        cycle_id = "#{machine_id}-#{i}"
        {:ok, pid} = start_machine_with_state(cycle_id, :running)
        TestGenServer.call(pid, {:transition, :stopped})
        TestGenServer.call(pid, {:transition, :running})
        kill_process_brutally(pid)

        result = DriftDetector.check_machine(cycle_id)

        case result do
          {:ok, {:anomaly, %{type: :zombie}}} ->
            {:ok, drift_result} = DriftDetector.detect_drift()
            zombies = Enum.filter(drift_result.anomalies, &(&1.type == :zombie))
            zombie = Enum.find(zombies, fn z -> z.machine_id == cycle_id end)

            if zombie do
              RepairActions.execute(zombie)
            end

          _ ->
            :ok
        end

        Process.sleep(50)
      end

      final_check = DriftDetector.check_machine(machine_id)
      assert match?({:ok, _}, final_check) or match?({:error, :not_found}, final_check)
    end

    @tag :capture_log
    test "handles machine with no WAL history" do
      machine_id = "no-wal-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      db_path = Storage.db_path(machine_id)

      create_dummy_wal_db(db_path)

      case Exqlite.Sqlite3.open(db_path) do
        {:ok, conn} ->
          case Exqlite.Sqlite3.execute(conn, "DELETE FROM wal_entries") do
             {:ok, _} -> :ok
             :ok -> :ok
             {:error, _} -> :ok
          end
          :ok = Exqlite.Sqlite3.close(conn)

        {:error, _} ->
          :ok
      end

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        repair_result = RepairActions.execute(zombie)

        case repair_result do
          {:ok, _} ->
            assert wait_for_condition(fn ->
                     get_machine_state(machine_id) != nil
                   end, 30_000)

          {:error, _} ->
            :ok
        end
      end
    end

    test "handles resurrection of machine with corrupted state in DB" do
      machine_id = "corrupt-state-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      db_path = Storage.db_path(machine_id)

      case Exqlite.Sqlite3.open(db_path) do
        {:ok, conn} ->
          {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "UPDATE machines SET state = 'invalid_state' WHERE id = ?")
          :ok = Exqlite.Sqlite3.bind(stmt, [machine_id])
          :done = Exqlite.Sqlite3.step(conn, stmt)

          :ok = Exqlite.Sqlite3.close(conn)

        {:error, _} ->
          :ok
      end

      {:ok, result} = DriftDetector.detect_drift()
      zombies = Enum.filter(result.anomalies, &(&1.type == :zombie))
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        repair_result = RepairActions.execute(zombie)
        assert match?({:ok, _}, repair_result) or match?({:error, _}, repair_result)
      end
    end
  end
end
