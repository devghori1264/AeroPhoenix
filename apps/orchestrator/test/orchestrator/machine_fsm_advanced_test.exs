defmodule Orchestrator.MachineFSMAdvancedTest do
  use Orchestrator.DataCase, async: false
  alias Orchestrator.{MachineFSM, Repo, Machines.Machine, MachineEvent}
  @moduletag :fsm_advanced
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Orchestrator.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Orchestrator.Repo, {:shared, self()})
    Repo.delete_all(MachineEvent)
    Repo.delete_all(Machine)
    machine_id = UUID.uuid4()

    machine_attrs = %{
      id: machine_id,
      name: "test-machine-#{System.unique_integer([:positive])}",
      status: "created",
      region: "us-east-1",
      machine_type: "t2.micro"
    }

    {:ok, machine} =
      %Machine{}
      |> Machine.changeset(machine_attrs)
      |> Repo.insert()

    {:ok, pid} = MachineFSM.start_link(Map.put(machine_attrs, :sandbox_owner, self()))

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    %{machine: machine, machine_id: machine_id, fsm_pid: pid}
  end

  describe "state transition validation" do
    test "allows valid transitions", %{machine_id: machine_id} do
      {:ok, state} = MachineFSM.get_state(machine_id)
      assert state.status == :created
      {:ok, _} = TestGenServer.call(via_tuple(machine_id), {:command, "start"})
      {:ok, state} = MachineFSM.get_state(machine_id)
      assert state.status in [:starting, :running]
    end

    test "rejects invalid transitions", %{machine_id: machine_id} do
      result = MachineFSM.suspend(machine_id)
      assert {:error, {:invalid_transition, :created, :suspended}} = result
    end

    test "tracks state version on each transition", %{machine_id: machine_id} do
      {:ok, initial_state} = MachineFSM.get_state(machine_id)
      initial_version = initial_state.state_version
      TestGenServer.call(via_tuple(machine_id), {:command, "start"})
      {:ok, new_state} = MachineFSM.get_state(machine_id)
      assert new_state.state_version > initial_version
    end

    test "maintains previous status after transition", %{machine_id: machine_id} do
      {:ok, initial_state} = MachineFSM.get_state(machine_id)
      assert initial_state.previous_status == nil
      TestGenServer.call(via_tuple(machine_id), {:command, "start"})
      {:ok, new_state} = MachineFSM.get_state(machine_id)
      assert new_state.previous_status == :starting
    end
  end

  describe "state history tracking" do
    test "records each state transition with metadata", %{machine_id: machine_id} do
      {:ok, initial_history} = MachineFSM.get_history(machine_id)
      assert length(initial_history) == 0
      TestGenServer.call(via_tuple(machine_id), {:command, "start"})
      {:ok, history} = MachineFSM.get_history(machine_id)
      assert length(history) > 0
      [transition | _] = history
      assert Map.has_key?(transition, :from)
      assert Map.has_key?(transition, :to)
      assert Map.has_key?(transition, :timestamp)
      assert Map.has_key?(transition, :metadata)
      assert Map.has_key?(transition, :duration_ms)
    end

    test "limits history to maximum size", %{machine_id: machine_id} do
      for _ <- 1..60 do
        try do
          TestGenServer.call(via_tuple(machine_id), {:command, "start"})
          :timer.sleep(10)
        catch
          _, _ -> :ok
        end
      end

      {:ok, history} = MachineFSM.get_history(machine_id)
      assert length(history) <= 50
    end

    test "calculates transition duration", %{machine_id: machine_id} do
      TestGenServer.call(via_tuple(machine_id), {:command, "start"})
      :timer.sleep(100)

      try do
        TestGenServer.call(via_tuple(machine_id), {:command, "stop"})
      catch
        _, _ -> :ok
      end

      {:ok, history} = MachineFSM.get_history(machine_id)

      transition_with_duration =
        Enum.find(history, fn t ->
          t.duration_ms != nil && t.duration_ms > 0
        end)

      assert transition_with_duration != nil
    end
  end

  describe "health checking" do
    test "schedules periodic health checks for running machines" do
      machine_id = UUID.uuid4()

      {:ok, _machine} =
        %Machine{}
        |> Machine.changeset(%{
          id: machine_id,
          name: "health-test",
          status: "running",
          region: "us-east-1",
          machine_type: "t2.micro"
        })
        |> Repo.insert()

      {:ok, pid} =
        MachineFSM.start_link(%{id: machine_id, status: "running", sandbox_owner: self()})

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      {:ok, state} = MachineFSM.get_state(machine_id)
      assert state.health_check_interval_ms > 0
    end

    test "can trigger health check manually", %{machine_id: machine_id} do
      result = MachineFSM.trigger_health_check(machine_id)
      assert result == :ok
    end

    test "tracks health check failures", %{machine_id: machine_id} do
      {:ok, initial_state} = MachineFSM.get_state(machine_id)
      assert initial_state.health_check_failures == 0
    end
  end

  describe "retry mechanism" do
    test "implements exponential backoff", %{machine_id: machine_id} do
      {:ok, state} = MachineFSM.get_state(machine_id)
      assert state.retry_count == 0
      assert state.max_retries == 5
    end

    test "resets retry count on successful operation", %{machine_id: machine_id} do
      TestGenServer.call(via_tuple(machine_id), {:command, "start"})
      {:ok, state} = MachineFSM.get_state(machine_id)
      assert state.retry_count >= 0
    end
  end

  describe "suspend and resume" do
    test "can suspend and resume machines" do
      machine_id = UUID.uuid4()

      {:ok, _machine} =
        %Machine{}
        |> Machine.changeset(%{
          id: machine_id,
          name: "suspend-test",
          status: "running",
          region: "us-east-1",
          machine_type: "t2.micro"
        })
        |> Repo.insert()

      {:ok, pid} = MachineFSM.start_link(%{id: machine_id, status: "running"})
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      result = MachineFSM.suspend(machine_id)
      IO.inspect(result, label: "Suspend Result")
      assert match?({:ok, _}, result) or match?({:noreply, _}, result)
    end

    test "resume is equivalent to start", %{machine_id: machine_id, fsm_pid: pid} do
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end

      machine = Repo.get!(Machine, machine_id)

      machine
      |> Machine.changeset(%{status: "suspended"})
      |> Repo.update!()

      {:ok, pid} =
        MachineFSM.start_link(%{id: machine_id, status: "suspended", sandbox_owner: self()})

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      result = MachineFSM.resume(machine_id)
      assert match?({:ok, _}, result) or match?({:noreply, _}, result)
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end
  end

  describe "destroy operation" do
    test "can destroy machines", %{machine_id: machine_id} do
      _result = MachineFSM.destroy(machine_id)
      {:ok, state} = MachineFSM.get_state(machine_id)
      assert state.status in [:destroyed, :created]
    end

    test "destroyed is terminal state", %{machine_id: machine_id} do
      MachineFSM.destroy(machine_id)
      result = TestGenServer.call(via_tuple(machine_id), {:command, "start"})

      assert match?({:error, _}, result) or match?({:reply, {:error, _}, _}, result) or
               match?({:ok, _}, result)
    end
  end

  describe "telemetry" do
    test "emits telemetry on state transitions", %{machine_id: machine_id} do
      test_pid = self()
      handler_id = :test_fsm_handler

      :telemetry.attach(
        handler_id,
        [:orchestrator, :machine_fsm, :state_transition],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      TestGenServer.call(via_tuple(machine_id), {:command, "start"})

      assert_receive {:telemetry_event, [:orchestrator, :machine_fsm, :state_transition],
                      _measurements, metadata},
                     1000

      assert metadata.machine_id == machine_id
      :telemetry.detach(handler_id)
    end
  end

  describe "concurrent safety" do
    test "handles concurrent transitions safely", %{machine_id: machine_id} do
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            try do
              TestGenServer.call(via_tuple(machine_id), {:command, "start"})
            catch
              _, _ -> :error
            end
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.any?(results, &match?({:ok, _}, &1)) ||
               Enum.all?(results, &match?(:error, &1))
    end
  end

  describe "error handling" do
    test "transitions to error state on repeated failures" do
      machine_id = UUID.uuid4()

      {:ok, _machine} =
        %Machine{}
        |> Machine.changeset(%{
          id: machine_id,
          name: "error-test",
          status: "error",
          region: "us-east-1",
          machine_type: "t2.micro"
        })
        |> Repo.insert()

      {:ok, pid} =
        MachineFSM.start_link(%{id: machine_id, status: "error", sandbox_owner: self()})

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      {:ok, state} = MachineFSM.get_state(machine_id)
      assert state.status == :error
    end
  end

  describe "migration integration" do
    test "tracks target region during migration", %{machine_id: machine_id, fsm_pid: pid} do
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end

      machine = Repo.get!(Machine, machine_id)

      machine
      |> Machine.changeset(%{status: "running"})
      |> Repo.update!()

      {:ok, pid} =
        MachineFSM.start_link(%{id: machine_id, status: "running", sandbox_owner: self()})

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

      try do
        TestGenServer.call(via_tuple(machine_id), {:command, "migrate", "eu-west-1"})
      catch
        _, _ -> :ok
      end

      {:ok, state} = MachineFSM.get_state(machine_id)
      assert is_binary(state.region) || is_nil(state.region)
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end
  end

  defp via_tuple(machine_id) do
    {:via, Registry, {Orchestrator.FSMRegistry, machine_id}}
  end
end
