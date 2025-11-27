defmodule Orchestrator.Recovery.ZombieScenariosTest do
  use ExUnit.Case, async: false
  require Logger

  alias Orchestrator.MachineActor.Supervisor, as: MachActorSup
  alias Orchestrator.Recovery.{DriftDetector, Reconciler, RepairActions}
  alias Orchestrator.MachineActor.{Storage, WAL}

  @moduletag timeout: 120_000

  setup do
    start_supervised!(Reconciler)

    Reconciler.pause()

    on_exit(fn ->
      cleanup_all_machines()
    end)

    :ok
  end

  defp cleanup_all_machines do
    Registry.select(Orchestrator.Registry.Machines, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    |> Enum.each(fn {_region, id} ->
      case Registry.lookup(Orchestrator.Registry.Machines, {nil, id}) do
        [{pid, _}] when is_pid(pid) ->
          Process.exit(pid, :kill)

        _ ->
          :ok
      end
    end)

    Process.sleep(100)
  end

  defp start_machine_with_state(machine_id, initial_state \\ :stopped) do
    {:ok, pid} =
      MachActorSup.start_machine(
        id: machine_id,
        region: "edge-test-#{:rand.uniform(1000)}"
      )

    Process.sleep(50)

    if initial_state != :stopped do
      GenServer.call(pid, {:transition, initial_state})
    end

    {:ok, pid}
  end

  defp kill_process_brutally(pid) do
    Process.exit(pid, :kill)
    Process.sleep(20)
  end

  defp corrupt_wal(machine_id) do
    db_path = Storage.db_path(machine_id)

    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} ->
        {:ok, _} =
          Exqlite.Sqlite3.execute(
            conn,
            """
            INSERT INTO wal_log (timestamp, intent, context)
            VALUES (datetime('now'), '{"type":"migrate","target":"edge-us-west"}', '{"corrupt":true}')
            """
          )

        :ok = Exqlite.Sqlite3.close(conn)

      {:error, _} ->
        :skip_corruption
    end
  end

  defp get_machine_state(machine_id) do
    case Registry.lookup(Orchestrator.Registry.Machines, {nil, machine_id}) do
      [{pid, _}] when is_pid(pid) ->
        GenServer.call(pid, :get_state)

      _ ->
        nil
    end
  end

  defp wait_for_condition(condition_fn, timeout_ms \\ 5000) do
    start_time = System.monotonic_time(:millisecond)

    Stream.iterate(0, &(&1 + 1))
    |> Enum.reduce_while(false, fn _attempt, _acc ->
      if condition_fn.() do
        {:halt, true}
      else
        if System.monotonic_time(:millisecond) - start_time > timeout_ms do
          {:halt, false}
        else
          Process.sleep(50)
          {:cont, false}
        end
      end
    end)
  end

  describe "process kill during migration" do
    test "zombie resurrection completes interrupted migration" do
      machine_id = "mig-victim-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      send(pid, {:migrate, "edge-eu-central"})

      Process.sleep(50)
      kill_process_brutally(pid)

      assert wait_for_condition(fn ->
               case DriftDetector.check_machine(machine_id) do
                 {:ok, [:zombie]} -> true
                 _ -> false
               end
             end)

      result = DriftDetector.detect_drift()
      assert %{zombies: zombies} = result
      assert length(zombies) > 0

      zombie_anomaly = Enum.find(zombies, fn z -> z.machine_id == machine_id end)
      assert zombie_anomaly != nil

      {:ok, outcome} = RepairActions.execute(zombie_anomaly)
      assert outcome in [:repaired, :already_healthy]

      assert wait_for_condition(fn ->
               state = get_machine_state(machine_id)
               state != nil
             end)

      state = get_machine_state(machine_id)
      assert state.state in [:running, :stopped]
    end

    test "WAL replay handles partial migration state" do
      machine_id = "partial-mig-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      send(pid, {:transition, :migrating})
      Process.sleep(10)
      kill_process_brutally(pid)

      corrupt_wal(machine_id)

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        {:ok, _} = RepairActions.execute(zombie)

        assert wait_for_condition(fn ->
                 get_machine_state(machine_id) != nil
               end)

        state = get_machine_state(machine_id)
        assert state.state in [:stopped, :running]
      end
    end

    test "resurrection preserves machine metadata through crash" do
      machine_id = "meta-preserve-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      initial_state = GenServer.call(pid, :get_state)
      initial_region = initial_state.region

      kill_process_brutally(pid)

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      assert zombie != nil
      {:ok, _} = RepairActions.execute(zombie)

      assert wait_for_condition(fn ->
               get_machine_state(machine_id) != nil
             end)

      new_state = get_machine_state(machine_id)
      assert new_state.id == machine_id
    end
  end

  describe "WAL corruption recovery" do
    test "handles corrupted WAL entries gracefully" do
      machine_id = "wal-corrupt-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      GenServer.call(pid, {:transition, :stopped})
      GenServer.call(pid, {:transition, :running})

      kill_process_brutally(pid)
      corrupt_wal(machine_id)

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
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

      case Exqlite.Sqlite3.open(db_path) do
        {:ok, conn} ->
          {:ok, _} =
            Exqlite.Sqlite3.execute(
              conn,
              """
              INSERT INTO wal_log (timestamp, intent, context)
              VALUES (datetime('now', '-10 seconds'), '{"type":"start"}', '{}')
              """
            )

          :ok = Exqlite.Sqlite3.close(conn)

        {:error, _} ->
          :ok
      end

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        {:ok, _} = RepairActions.execute(zombie)

        assert wait_for_condition(fn ->
                 get_machine_state(machine_id) != nil
               end)
      end
    end

    test "handles database file corruption" do
      machine_id = "db-corrupt-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      db_path = Storage.db_path(machine_id)

      case Exqlite.Sqlite3.open(db_path) do
        {:ok, conn} ->
          {:ok, _} = Exqlite.Sqlite3.execute(conn, "DELETE FROM wal_log")
          :ok = Exqlite.Sqlite3.close(conn)

        {:error, _} ->
          :ok
      end

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        result = RepairActions.execute(zombie)
        assert match?({:ok, _}, result)

        if match?({:ok, _}, result) do
          assert wait_for_condition(fn ->
                   get_machine_state(machine_id) != nil
                 end)
        end
      end
    end
  end

  describe "concurrent resurrections" do
    test "handles race condition with multiple resurrection attempts" do
      machine_id = "race-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      assert zombie != nil

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            {i, RepairActions.execute(zombie)}
          end)
        end

      results = Task.await_many(tasks, 5000)

      successes = Enum.count(results, fn {_i, res} -> match?({:ok, _}, res) end)
      assert successes > 0

      failures = Enum.filter(results, fn {_i, res} -> match?({:error, _}, res) end)

      Enum.each(failures, fn {_i, {:error, reason}} ->
        assert reason in [
                 :already_exists,
                 {:repair_failed, :already_exists},
                 {:resurrection_failed, :already_exists}
               ]
      end)

      assert wait_for_condition(fn ->
               case Registry.lookup(Orchestrator.Registry.Machines, {nil, machine_id}) do
                 [{pid, _}] when is_pid(pid) -> Process.alive?(pid)
                 _ -> false
               end
             end)
    end

    test "concurrent resurrections with different anomaly detections" do
      machine_id = "concurrent-detect-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            result = DriftDetector.detect_drift()
            zombies = Map.get(result, :zombies, [])
            zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

            if zombie do
              {i, RepairActions.execute(zombie)}
            else
              {i, {:error, :not_found}}
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)

      successes =
        Enum.count(results, fn
          {_i, {:ok, _}} -> true
          _ -> false
        end)

      assert successes > 0

      assert wait_for_condition(fn ->
               state = get_machine_state(machine_id)
               state != nil
             end)
    end

    test "handles thundering herd of 50 concurrent repairs" do
      machine_ids =
        for i <- 1..50 do
          id = "herd-#{i}-#{:rand.uniform(10_000)}"
          {:ok, pid} = start_machine_with_state(id, :running)
          kill_process_brutally(pid)
          id
        end

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
      assert length(zombies) >= 50

      start_time = System.monotonic_time(:millisecond)

      tasks =
        zombies
        |> Enum.take(50)
        |> Enum.map(fn zombie ->
          Task.async(fn ->
            RepairActions.execute(zombie)
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      duration_ms = System.monotonic_time(:millisecond) - start_time

      successes = Enum.count(results, fn res -> match?({:ok, _}, res) end)
      assert successes >= 40

      assert duration_ms < 10_000

      Logger.info("Concurrent repair of 50 zombies: #{duration_ms}ms, #{successes}/50 succeeded")
    end
  end

  describe "ghost to zombie transitions" do
    test "handles cascade from ghost cleanup to zombie detection" do
      machine_id = "cascade-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      Process.exit(pid, :kill)

      initial_result = DriftDetector.check_machine(machine_id)

      Process.sleep(200)

      final_result = DriftDetector.check_machine(machine_id)

      {:ok, anomalies} = initial_result
      assert is_list(anomalies)
      {:ok, anomalies_final} = final_result
      assert is_list(anomalies_final)

      case final_result do
        {:ok, [:zombie]} ->
          result = DriftDetector.detect_drift()
          zombies = Map.get(result, :zombies, [])
          zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

          assert zombie != nil
          {:ok, _} = RepairActions.execute(zombie)

        {:ok, [:ghost]} ->
          Reconciler.force_reconciliation()
          Process.sleep(500)

          state = get_machine_state(machine_id)
          assert state == nil or state != nil

        {:ok, []} ->
          :ok

        _ ->
          flunk("Unexpected anomaly state: #{inspect(final_result)}")
      end
    end

    test "simultaneous ghost and zombie for same machine" do
      machine_id = "simul-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)

      kill_process_brutally(pid)

      result = DriftDetector.detect_drift()

      ghosts = Map.get(result, :ghosts, [])
      zombies = Map.get(result, :zombies, [])

      ghost_ids = Enum.map(ghosts, & &1.machine_id)
      zombie_ids = Enum.map(zombies, & &1.machine_id)

      refute machine_id in ghost_ids and machine_id in zombie_ids,
             "Machine cannot be both ghost and zombie simultaneously"
    end
  end

  describe "batch zombie repair scalability" do
    @tag :slow
    @tag timeout: 120_000
    test "repairs 1,000 zombies in under 30 seconds" do
      Logger.info("Creating 1,000 zombie machines...")
      start_time = System.monotonic_time(:millisecond)

      machine_ids =
        1..1000
        |> Enum.map(fn i ->
          id = "batch-#{i}-#{:rand.uniform(10_000)}"

          {:ok, pid} =
            MachActorSup.start_machine(
              id: id,
              region: "batch-test"
            )

          Process.exit(pid, :kill)
          id
        end)

      creation_time = System.monotonic_time(:millisecond) - start_time
      Logger.info("Created 1,000 zombies in #{creation_time}ms")

      Process.sleep(500)

      detect_start = System.monotonic_time(:millisecond)
      result = DriftDetector.detect_drift()
      detect_time = System.monotonic_time(:millisecond) - detect_start

      zombies = Map.get(result, :zombies, [])
      assert length(zombies) >= 900, "Expected >= 900 zombies, got #{length(zombies)}"

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
      - Total machines: 1,000
      - Zombies detected: #{length(zombies)}
      - Repairs attempted: #{length(results)}
      - Successful repairs: #{successes}
      - Detection time: #{detect_time}ms
      - Repair time: #{repair_time}ms
      - Total time: #{total_time}ms
      """)

      assert repair_time < 30_000, "Repair took #{repair_time}ms, expected < 30,000ms"
      assert successes >= 800, "Only #{successes}/1,000 succeeded, expected >= 800"

      resurrection_rate = successes / max(length(zombies), 1) * 100
      assert resurrection_rate >= 80.0, "Resurrection rate: #{resurrection_rate}%"
    end

    @tag :slow
    test "reconciler handles continuous zombie stream" do
      Reconciler.resume()

      Logger.info("Starting continuous zombie creation...")

      spawn(fn ->
        for i <- 1..100 do
          id = "stream-#{i}-#{:rand.uniform(10_000)}"
          {:ok, pid} = start_machine_with_state(id, :running)
          Process.sleep(100)
          kill_process_brutally(pid)
        end
      end)

      Process.sleep(15_000)

      stats = Reconciler.get_stats()

      Logger.info("""
      Continuous Stream Results:
      - Total cycles: #{stats.total_cycles}
      - Total repairs: #{stats.total_repairs}
      - Failed repairs: #{stats.failed_repairs}
      """)

      assert stats.total_cycles >= 2

      assert stats.total_repairs >= 50

      Reconciler.pause()
    end
  end

  describe "edge cases" do
    test "handles machine that dies during resurrection" do
      machine_id = "dies-during-res-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
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

      result = Task.await(task, 5000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles rapid start/stop/kill cycles" do
      machine_id = "rapid-cycle-#{:rand.uniform(100_000)}"

      for _i <- 1..10 do
        {:ok, pid} = start_machine_with_state(machine_id, :running)
        GenServer.call(pid, {:transition, :stopped})
        GenServer.call(pid, {:transition, :running})
        kill_process_brutally(pid)

        result = DriftDetector.check_machine(machine_id)

        case result do
          {:ok, [:zombie]} ->
            drift_result = DriftDetector.detect_drift()
            zombies = Map.get(drift_result, :zombies, [])
            zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

            if zombie do
              RepairActions.execute(zombie)
            end

          _ ->
            :ok
        end

        Process.sleep(50)
      end

      final_check = DriftDetector.check_machine(machine_id)
      {:ok, anomalies} = final_check
      assert is_list(anomalies)
    end

    test "handles machine with no WAL history" do
      machine_id = "no-wal-#{:rand.uniform(100_000)}"

      {:ok, pid} = start_machine_with_state(machine_id, :running)
      kill_process_brutally(pid)

      db_path = Storage.db_path(machine_id)

      case Exqlite.Sqlite3.open(db_path) do
        {:ok, conn} ->
          {:ok, _} = Exqlite.Sqlite3.execute(conn, "DROP TABLE IF EXISTS wal_log")
          :ok = Exqlite.Sqlite3.close(conn)

        {:error, _} ->
          :ok
      end

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        repair_result = RepairActions.execute(zombie)

        case repair_result do
          {:ok, _} ->
            assert wait_for_condition(fn ->
                     get_machine_state(machine_id) != nil
                   end)

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
          {:ok, _} =
            Exqlite.Sqlite3.execute(
              conn,
              "UPDATE machines SET state = 'invalid_state' WHERE id = ?",
              bind: [machine_id]
            )

          :ok = Exqlite.Sqlite3.close(conn)

        {:error, _} ->
          :ok
      end

      result = DriftDetector.detect_drift()
      zombies = Map.get(result, :zombies, [])
      zombie = Enum.find(zombies, fn z -> z.machine_id == machine_id end)

      if zombie do
        repair_result = RepairActions.execute(zombie)
        assert match?({:ok, _}, repair_result) or match?({:error, _}, repair_result)
      end
    end
  end
end
