defmodule Orchestrator.MachineActorTest do
  use ExUnit.Case, async: false

  alias Orchestrator.MachineActor
  alias Orchestrator.MachineActor.{Supervisor, Storage, WAL, FSM}

  @moduletag :capture_log

  setup do
    start_supervised!(Orchestrator.FlydSim)
    data_dir = "tmp/test_machines"
    File.mkdir_p!(data_dir)

    Application.put_env(:orchestrator, :machine_actor_data_dir, data_dir)

    on_exit(fn ->
      Supervisor.list_machines()
      |> Enum.each(fn id ->
        try do
          Supervisor.stop_machine(id)
        rescue
          _ -> :ok
        end
      end)

      Enum.reduce_while(1..5, :error, fn _, _ ->
        try do
          File.rm_rf!(data_dir)
          {:halt, :ok}
        rescue
          _ ->
            Process.sleep(100)
            {:cont, :error}
        end
      end)
    end)

    {:ok, data_dir: data_dir}
  end

  describe "MachineActor lifecycle" do
    test "starts with fresh state", %{data_dir: _} do
      machine_id = "m_test_#{:rand.uniform(10000)}"

      {:ok, pid} =
        Supervisor.start_machine(
          id: machine_id,
          region: "us-east-1",
          image: "test/app:v1.0.0",
          size: %{cpu_count: 2, memory_mb: 1024}
        )

      assert Process.alive?(pid)

      {:ok, state} = MachineActor.get_snapshot(pid)
      assert state.id == machine_id
      assert state.state == :created
      assert state.region == "us-east-1"
      assert state.locked_by == nil

      :ok = Supervisor.stop_machine(machine_id)
    end

    test "recovers state from SQLite on restart", %{data_dir: data_dir} do
      machine_id = "m_recovery_test_#{:rand.uniform(10000)}"

      {:ok, pid} =
        Supervisor.start_machine(
          id: machine_id,
          region: "eu-west-1",
          image: "test/app:v2.0.0"
        )

      {:ok, _result} = MachineActor.transition(pid, :start)

      Process.sleep(200)

      {:ok, state_before} = MachineActor.get_snapshot(pid)
      assert state_before.state == :running

      Process.exit(pid, :kill)
      Process.sleep(100)

      {:ok, new_pid} = Supervisor.restart_machine(machine_id)

      {:ok, state_after} = MachineActor.get_snapshot(new_pid)
      assert state_after.id == machine_id
      assert state_after.state == :running
      assert state_after.region == "eu-west-1"

      db_path = Path.join(data_dir, "#{machine_id}.db")
      assert File.exists?(db_path)

      :ok = Supervisor.stop_machine(machine_id)
    end

    test "prevents duplicate machine IDs" do
      machine_id = "m_duplicate_test"

      {:ok, _pid} =
        Supervisor.start_machine(
          id: machine_id,
          region: "us-west-1"
        )

      {:error, :already_exists} =
        Supervisor.start_machine(
          id: machine_id,
          region: "us-west-1"
        )

      :ok = Supervisor.stop_machine(machine_id)
    end
  end

  describe "FSM state transitions" do
    setup do
      machine_id = "m_fsm_test_#{:rand.uniform(10000)}"

      {:ok, pid} =
        Supervisor.start_machine(
          id: machine_id,
          region: "us-east-1"
        )

      on_exit(fn ->
        Supervisor.stop_machine(machine_id)
      end)

      {:ok, pid: pid, machine_id: machine_id}
    end

    test "validates legal transitions", %{pid: _pid} do
      assert FSM.validate_transition(:created, :starting) == :ok

      assert {:error, {:invalid_transition, :created, :running}} =
               FSM.validate_transition(:created, :running)

      assert {:error, {:invalid_transition, :destroyed, :starting}} =
               FSM.validate_transition(:destroyed, :starting)
    end

    test "performs valid state transition", %{pid: pid} do
      {:ok, result} = MachineActor.transition(pid, :start)

      assert result.from == :created
      assert result.to == :starting
      assert %DateTime{} = result.timestamp

      Process.sleep(200)

      {:ok, state} = MachineActor.get_snapshot(pid)
      assert state.state == :running
    end

    test "rejects invalid transitions", %{pid: pid} do
      {:error, reason} = MachineActor.transition(pid, :migrate, target_region: "eu-west-1")

      assert reason ==
               {:precondition_failed, "machine must be running or stopped to migrate"}
    end

    test "enforces operation lock (no concurrent transitions)", %{pid: pid} do
      task1 = Task.async(fn -> MachineActor.transition(pid, :start) end)

      wait_for_lock(pid)

      {:error, {:locked_by_operation, _op_id}} =
        MachineActor.transition(pid, :start)

      {:ok, _result} = Task.await(task1)
    end

    test "respects capability restrictions", %{pid: _pid} do
      machine_id = "m_restricted_#{:rand.uniform(10000)}"

      {:ok, restricted_pid} =
        Supervisor.start_machine(
          id: machine_id,
          region: "us-east-1",
          capabilities: [:start, :stop]
        )

      {:ok, _} = MachineActor.transition(restricted_pid, :start)
      Process.sleep(200)

      {:ok, _} = MachineActor.transition(restricted_pid, :stop)
      Process.sleep(100)

      {:error, {:missing_capability, :migrate}} =
        MachineActor.transition(restricted_pid, :migrate, target_region: "eu-west-1")

      :ok = Supervisor.stop_machine(machine_id)
    end
  end

  describe "Write-Ahead Log" do
    test "records all transitions", %{data_dir: _data_dir} do
      machine_id = "m_wal_test_#{:rand.uniform(10000)}"

      {:ok, pid} =
        Supervisor.start_machine(
          id: machine_id,
          region: "us-east-1"
        )

      {:ok, _} = MachineActor.transition(pid, :start)
      Process.sleep(200)

      {:ok, _} = MachineActor.transition(pid, :stop)
      Process.sleep(100)

      {:ok, _} = MachineActor.transition(pid, :start)
      Process.sleep(200)

      {:ok, history} = MachineActor.get_history(pid, limit: 10)

      assert length(history) == 3
      assert Enum.at(history, 0).transition_type == :start
      assert Enum.at(history, 1).transition_type == :stop
      assert Enum.at(history, 2).transition_type == :start

      assert Enum.all?(history, &(&1.status == :completed))

      :ok = Supervisor.stop_machine(machine_id)
    end

    test "replays WAL on crash recovery", %{data_dir: data_dir} do
      machine_id = "m_wal_replay_#{:rand.uniform(10000)}"
      db_path = Path.join(data_dir, "#{machine_id}.db")

      {:ok, conn} = Storage.init(db_path)

      metadata = %{
        id: machine_id,
        region: "us-east-1",
        state: :created,
        image: "test/app:v1.0.0",
        size: %{cpu_count: 1, memory_mb: 256},
        capabilities: [:start, :stop],
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now(),
        version: 1
      }

      :ok = Storage.save_metadata(conn, metadata)

      {:ok, _seq1} =
        WAL.append(conn, %{
          operation_id: "op_1",
          from_state: :created,
          to_state: :starting,
          transition_type: :start,
          opts: [],
          timestamp: DateTime.utc_now(),
          status: :pending
        })

      :ok = WAL.mark_completed(conn, "op_1")

      {:ok, _seq2} =
        WAL.append(conn, %{
          operation_id: "op_2",
          from_state: :starting,
          to_state: :running,
          transition_type: :provision_complete,
          opts: [],
          timestamp: DateTime.utc_now(),
          status: :pending
        })

      :ok = WAL.mark_completed(conn, "op_2")

      Storage.close(conn)

      {:ok, pid} = Supervisor.start_machine(id: machine_id, region: "us-east-1")

      {:ok, state} = MachineActor.get_snapshot(pid)
      assert state.state == :running

      :ok = Supervisor.stop_machine(machine_id)
    end

    test "detects pending operations on recovery", %{data_dir: data_dir} do
      machine_id = "m_pending_ops_#{:rand.uniform(10000)}"
      db_path = Path.join(data_dir, "#{machine_id}.db")

      {:ok, conn} = Storage.init(db_path)

      metadata = %{
        id: machine_id,
        region: "us-east-1",
        state: :created,
        image: nil,
        size: %{cpu_count: 1, memory_mb: 256},
        capabilities: [:start],
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now(),
        version: 1
      }

      :ok = Storage.save_metadata(conn, metadata)

      {:ok, _seq} =
        WAL.append(conn, %{
          operation_id: "op_crashed",
          from_state: :created,
          to_state: :starting,
          transition_type: :start,
          opts: [],
          timestamp: DateTime.utc_now(),
          status: :pending
        })

      Storage.close(conn)

      {:ok, _pid} = Supervisor.start_machine(id: machine_id, region: "us-east-1")

      :ok = Supervisor.stop_machine(machine_id)
    end
  end

  describe "Performance and stats" do
    test "tracks transition metrics", %{data_dir: _} do
      machine_id = "m_stats_test_#{:rand.uniform(10000)}"

      {:ok, pid} =
        Supervisor.start_machine(
          id: machine_id,
          region: "us-east-1"
        )

      Enum.each(1..5, fn _ ->
        {:ok, _} = MachineActor.transition(pid, :start)
        Process.sleep(200)
        {:ok, _} = MachineActor.transition(pid, :stop)
        Process.sleep(100)
      end)

      {:ok, state} = MachineActor.get_snapshot(pid)

      assert state.stats.transitions == 10
      assert state.stats.avg_transition_ms > 0.0
      assert state.stats.errors == 0

      :ok = Supervisor.stop_machine(machine_id)
    end
  end

  describe "Supervisor operations" do
    test "lists all running machines" do
      machine_ids = [
        "m_list_test_1_#{:rand.uniform(10000)}",
        "m_list_test_2_#{:rand.uniform(10000)}",
        "m_list_test_3_#{:rand.uniform(10000)}"
      ]

      Enum.each(machine_ids, fn id ->
        Supervisor.start_machine(id: id, region: "us-east-1")
      end)

      running = Supervisor.list_machines()

      Enum.each(machine_ids, fn id ->
        assert id in running
      end)

      Enum.each(machine_ids, &Supervisor.stop_machine/1)
    end

    test "counts active machines" do
      initial_count = Supervisor.count_machines()

      machine_id = "m_count_test_#{:rand.uniform(10000)}"
      {:ok, _pid} = Supervisor.start_machine(id: machine_id, region: "us-east-1")

      assert Supervisor.count_machines() == initial_count + 1

      :ok = Supervisor.stop_machine(machine_id)

      assert Supervisor.count_machines() == initial_count
    end
  end

  defp wait_for_lock(pid, attempts \\ 50) do
    case MachineActor.get_snapshot(pid) do
      {:ok, %{locked_by: locked}} when not is_nil(locked) ->
        :ok

      _ ->
        if attempts > 0 do
          Process.sleep(10)
          wait_for_lock(pid, attempts - 1)
        else
          flunk("Failed to acquire lock")
        end
    end
  end
end
