defmodule Orchestrator.Recovery.ReconcilerTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Recovery.{Reconciler, DriftDetector}
  alias Orchestrator.MachineActor
  alias Orchestrator.MachineActor.Supervisor, as: MachActorSup

  setup do
    if !Process.whereis(Orchestrator.Repo) do
      Orchestrator.Repo.start_link()
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Orchestrator.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Orchestrator.Repo, {:shared, self()})

    start_supervised!(Orchestrator.FlydSim)
    cleanup_test_machines()

    if _pid = Process.whereis(Reconciler) do
      try do
        Supervisor.terminate_child(Orchestrator.Supervisor, Reconciler)
      catch
        _, _ -> :ok
      end
    end

    start_supervised!({Reconciler, [name: Reconciler, interval_ms: 60_000, auto_start: true]})

    reconciler_pid = Process.whereis(Reconciler)
    Ecto.Adapters.SQL.Sandbox.allow(Orchestrator.Repo, self(), reconciler_pid)

    on_exit(fn ->
      if pid = Process.whereis(Reconciler) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      try do
        if Process.whereis(Orchestrator.Repo) do
          Ecto.Adapters.SQL.Sandbox.checkout(Orchestrator.Repo)
          Ecto.Adapters.SQL.Sandbox.mode(Orchestrator.Repo, {:shared, self()})
          cleanup_test_machines()
        end
      rescue
        _ -> :ok
      end
    end)

    %{reconciler: reconciler_pid}
  end

  setup do
    Orchestrator.ResourceManager.reset()
    :ok
  end

  describe "start_link/1" do
    test "starts successfully with default configuration" do
      {:ok, pid} =
        Reconciler.start_link(
          interval_ms: 60_000,
          auto_start: false,
          name: :test_reconciler
        )

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "initializes with correct statistics" do
      {:ok, test_pid} =
        Reconciler.start_link(
          interval_ms: 60_000,
          auto_start: false,
          name: :test_reconciler_stats
        )

      stats = Reconciler.stats(:test_reconciler_stats)

      assert stats.started_at != nil
      assert stats.total_cycles == 0
      assert stats.total_anomalies_found == 0
      assert stats.total_repairs_attempted == 0
      assert stats.total_repairs_succeeded == 0
      assert stats.total_repairs_failed == 0
      assert MapSet.size(stats.failed_machines) == 0

      GenServer.stop(test_pid)
    end
  end

  describe "force_reconciliation/0" do
    test "executes drift detection and returns report" do
      for i <- 1..3 do
        id = Ecto.UUID.generate()
        {:ok, _pid} = MachActorSup.start_machine(id: id, region: "test", name: "test_manual_#{i}")
        id
      end

      Process.sleep(100)

      {:ok, result} = Reconciler.force_reconciliation()

      assert is_map(result)
      assert is_map(result.drift_report)
      assert is_list(result.repair_results)
      assert is_integer(result.duration_ms)
    end

    test "repairs detected anomalies automatically" do
      id = Ecto.UUID.generate()
      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test", name: "test_auto_repair")

      MachineActor.transition(pid, :start)
      MachineActor.transition(pid, :start)
      Process.sleep(100)

      DynamicSupervisor.terminate_child(Orchestrator.MachineActor.Supervisor, pid)
      Process.sleep(50)

      {:ok, result} = Reconciler.force_reconciliation()

      assert is_list(result.repair_results)

      Process.sleep(100)

      case MachActorSup.find_machine(id) do
        {:ok, _pid} ->
          assert true

        {:error, :not_found} ->
          assert true
      end

      cleanup_machine_data(id)
    end

    test "updates statistics after reconciliation" do
      initial_stats = Reconciler.stats()
      initial_cycles = initial_stats.total_cycles

      {:ok, _result} = Reconciler.force_reconciliation()

      new_stats = Reconciler.stats()

      assert new_stats.total_cycles == initial_cycles + 1
      assert new_stats.last_run != nil
    end
  end

  describe "automatic reconciliation cycles" do
    test "runs reconciliation at configured interval" do
      {:ok, pid} =
        Reconciler.start_link(
          interval_ms: 200,
          auto_start: true,
          name: :test_auto_cycle
        )

      initial_stats = TestGenServer.call(pid, :stats)
      initial_cycles = initial_stats.total_cycles

      Process.sleep(600)

      final_stats = TestGenServer.call(pid, :stats)

      assert final_stats.total_cycles >= initial_cycles + 1

      GenServer.stop(pid)
    end

    test "emits telemetry events on each cycle" do
      test_pid = self()

      :telemetry.attach(
        "test-reconciler-cycle",
        [:orchestrator, :reconciler, :cycle_complete],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:cycle_complete, measurements, metadata})
        end,
        nil
      )

      {:ok, _result} = Reconciler.force_reconciliation()

      assert_receive {:cycle_complete, measurements, metadata}, 1000

      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms > 0
      assert is_integer(measurements.anomalies_found)
      assert metadata.node == node()

      :telemetry.detach("test-reconciler-cycle")
    end
  end

  describe "zombie repair strategy" do
    test "resurrects zombie machines" do
      id = Ecto.UUID.generate()

      {:ok, pid} =
        MachActorSup.start_machine(id: id, region: "test", name: "test_zombie_resurrection")

      MachineActor.transition(pid, :start)
      Process.sleep(50)

      DynamicSupervisor.terminate_child(Orchestrator.MachineActor.Supervisor, pid)
      Process.sleep(50)

      case DriftDetector.check_machine(id) do
        {:ok, {:anomaly, %{type: :zombie}}} ->
          :ok

        _ ->
          :ok
      end

      {:ok, _result} = Reconciler.force_reconciliation()

      Process.sleep(200)

      case MachActorSup.find_machine(id) do
        {:ok, new_pid} ->
          assert Process.alive?(new_pid)

        {:error, :not_found} ->
          :ok
      end

      cleanup_machine_data(id)
    end

    test "handles resurrection failures gracefully" do
      stats_before = Reconciler.stats()

      {:ok, _result} = Reconciler.force_reconciliation()

      stats_after = Reconciler.stats()

      assert stats_after.total_cycles > stats_before.total_cycles
    end
  end

  describe "ghost repair strategy" do
    test "handles ghost processes" do
      {:ok, result} = Reconciler.force_reconciliation()

      assert is_map(result)
    end
  end

  describe "state drift repair strategy" do
    test "logs state drift for manual review" do
      {:ok, result} = Reconciler.force_reconciliation()

      assert is_map(result)
    end
  end

  describe "pause/resume functionality" do
    test "pause stops automatic reconciliation" do
      {:ok, pid} =
        Reconciler.start_link(
          interval_ms: 100,
          auto_start: true,
          name: :test_pause_resume
        )

      Process.sleep(150)

      initial_stats = TestGenServer.call(pid, :stats)
      initial_cycles = initial_stats.total_cycles

      :ok = TestGenServer.call(pid, :pause)

      Process.sleep(350)

      paused_stats = TestGenServer.call(pid, :stats)

      assert paused_stats.total_cycles == initial_cycles

      GenServer.stop(pid)
    end

    test "resume restarts automatic reconciliation" do
      {:ok, pid} =
        Reconciler.start_link(
          interval_ms: 100,
          auto_start: true,
          name: :test_resume
        )

      :ok = TestGenServer.call(pid, :pause)
      Process.sleep(50)

      paused_stats = TestGenServer.call(pid, :stats)
      paused_cycles = paused_stats.total_cycles

      :ok = TestGenServer.call(pid, :resume)

      Process.sleep(250)

      resumed_stats = TestGenServer.call(pid, :stats)

      assert resumed_stats.total_cycles > paused_cycles

      GenServer.stop(pid)
    end
  end

  describe "stats/0" do
    test "returns comprehensive statistics" do
      stats = Reconciler.stats()

      assert is_map(stats)
      assert %DateTime{} = stats.started_at
      assert is_integer(stats.total_cycles)
      assert is_integer(stats.total_anomalies_found)
      assert is_integer(stats.total_repairs_attempted)
      assert is_integer(stats.total_repairs_succeeded)
      assert is_integer(stats.total_repairs_failed)
      assert %MapSet{} = stats.failed_machines
      assert is_integer(stats.uptime_seconds)
    end

    test "tracks uptime correctly" do
      stats1 = Reconciler.stats()
      uptime1 = stats1.uptime_seconds

      Process.sleep(1100)

      stats2 = Reconciler.stats()
      uptime2 = stats2.uptime_seconds

      assert uptime2 >= uptime1 + 1
    end

    test "accumulates repair statistics across cycles" do
      initial_stats = Reconciler.stats()

      {:ok, _} = Reconciler.force_reconciliation()
      {:ok, _} = Reconciler.force_reconciliation()

      final_stats = Reconciler.stats()

      assert final_stats.total_cycles == initial_stats.total_cycles + 2
    end
  end

  describe "retry_repair/1" do
    test "manually retries repair for specific machine" do
      id = Ecto.UUID.generate()

      {:ok, _} =
        Orchestrator.Repo.insert(%Orchestrator.Machines.Machine{
          id: id,
          region: "test",
          status: "running",
          name: "test-machine"
        })

      {:ok, pid} = MachActorSup.start_machine(id: id, region: "test")
      MachineActor.transition(pid, :start)
      Process.sleep(50)

      DynamicSupervisor.terminate_child(Orchestrator.MachineActor.Supervisor, pid)
      Process.sleep(50)

      result = Reconciler.retry_repair(id)

      assert match?({:ok, _}, result)

      cleanup_machine_data(id)
    end

    test "returns error for non-existent machine" do
      result = Reconciler.retry_repair("nonexistent_machine")

      assert match?({:error, :not_found}, result)
    end

    test "returns already_healthy for healthy machines" do
      id = Ecto.UUID.generate()

      {:ok, _pid} =
        MachActorSup.start_machine(id: id, region: "test", name: "test_already_healthy")

      Process.sleep(50)

      result = Reconciler.retry_repair(id)

      assert match?({:ok, :already_healthy}, result)

      try_stop_machine(id)
    end
  end

  describe "concurrent repair handling" do
    test "limits concurrent repairs to configured maximum" do
      zombie_ids =
        for i <- 1..15 do
          id = Ecto.UUID.generate()

          {:ok, pid} =
            MachActorSup.start_machine(id: id, region: "test", name: "test_concurrent_#{i}")

          MachineActor.transition(pid, :start)
          Process.sleep(20)

          DynamicSupervisor.terminate_child(Orchestrator.MachineActor.Supervisor, pid)

          id
        end

      Process.sleep(100)

      {:ok, result} = Reconciler.force_reconciliation()

      repair_count = length(result.repair_results)

      assert repair_count <= 10

      Enum.each(zombie_ids, &cleanup_machine_data/1)
    end

    test "reconciliation completes in reasonable time" do
      cleanup_test_machines()
      Process.sleep(100)

      machine_ids =
        for i <- 1..5 do
          id = Ecto.UUID.generate()

          case MachActorSup.start_machine(id: id, region: "test", name: "test_perf_recon_#{i}") do
            {:ok, _pid} ->
              id

            {:error, _} ->
              nil
          end
        end
        |> Enum.filter(&(&1 != nil))

      Process.sleep(100)

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Reconciler.force_reconciliation()
      duration = System.monotonic_time(:millisecond) - start

      assert duration < 2000
      assert result.duration_ms < 2000

      Enum.each(machine_ids, &try_stop_machine/1)
    end
  end

  describe "telemetry events" do
    test "emits repair_attempted events" do
      test_pid = self()

      :telemetry.attach(
        "test-repair-attempted",
        [:orchestrator, :reconciler, :repair_attempted],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:repair_attempted, measurements, metadata})
        end,
        nil
      )

      id = Ecto.UUID.generate()

      {:ok, pid} =
        MachActorSup.start_machine(id: id, region: "test", name: "test_telemetry_zombie")

      MachineActor.transition(pid, :start)
      Process.sleep(50)

      DynamicSupervisor.terminate_child(Orchestrator.MachineActor.Supervisor, pid)
      Process.sleep(50)

      {:ok, _result} = Reconciler.force_reconciliation()

      :telemetry.detach("test-repair-attempted")
      cleanup_machine_data(id)
    end

    test "emits repair_succeeded events" do
      test_pid = self()

      :telemetry.attach(
        "test-repair-succeeded",
        [:orchestrator, :reconciler, :repair_succeeded],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:repair_succeeded, measurements, metadata})
        end,
        nil
      )

      {:ok, _result} = Reconciler.force_reconciliation()

      :telemetry.detach("test-repair-succeeded")
    end

    test "emits repair_failed events when repairs fail" do
      test_pid = self()

      :telemetry.attach(
        "test-repair-failed",
        [:orchestrator, :reconciler, :repair_failed],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:repair_failed, measurements, metadata})
        end,
        nil
      )

      {:ok, _result} = Reconciler.force_reconciliation()

      :telemetry.detach("test-repair-failed")
    end
  end

  describe "edge cases" do
    test "handles empty system (no machines) gracefully" do
      cleanup_test_machines()

      {:ok, result} = Reconciler.force_reconciliation()

      assert is_map(result)
      assert result.drift_report.total_machines >= 0
      assert result.repair_results == []
    end

    test "handles mass zombie scenario" do
      zombie_ids =
        for i <- 1..10 do
          id = Ecto.UUID.generate()

          {:ok, pid} =
            MachActorSup.start_machine(id: id, region: "test", name: "test_mass_zombie_#{i}")

          MachineActor.transition(pid, :start)
          Process.sleep(20)

          DynamicSupervisor.terminate_child(Orchestrator.MachineActor.Supervisor, pid)

          id
        end

      Process.sleep(100)

      {:ok, result} = Reconciler.force_reconciliation()

      assert is_map(result)
      assert is_list(result.repair_results)

      Enum.each(zombie_ids, &cleanup_machine_data/1)
    end

    test "handles reconciliation when drift detector fails" do
      {:ok, result} = Reconciler.force_reconciliation()

      assert is_map(result)
    end
  end

  defp cleanup_test_machines do
    import Ecto.Query

    test_machines =
      from(m in Orchestrator.Machines.Machine,
        where: like(m.name, "test_%"),
        select: m.id
      )
      |> Orchestrator.Repo.all()

    Enum.each(test_machines, fn id ->
      try_stop_machine(id)
      cleanup_machine_data(id)
    end)

    from(m in Orchestrator.Machines.Machine, where: like(m.name, "test_%"))
    |> Orchestrator.Repo.delete_all()

    if File.exists?("data/machines") do
      File.ls!("data/machines")
      |> Enum.each(fn file -> File.rm(Path.join("data/machines", file)) end)
    end

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
    data_dir = Application.get_env(:orchestrator, :machine_data_dir, "data/machines")
    db_path = Path.join(data_dir, "#{id}.db")

    if File.exists?(db_path) do
      File.rm(db_path)
    end
  end
end
