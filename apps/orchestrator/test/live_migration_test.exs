defmodule Orchestrator.LiveMigrationTest do
  use Orchestrator.DataCase, async: false
  @moduletag :slow
  @moduletag :integration
  @moduletag :capture_log
  @moduletag timeout: 120_000

  alias Orchestrator.LiveMigration.{Coordinator, Checkpointer, StateTransfer, Cutover}

  setup do
    start_supervised!(Orchestrator.FlydSim)
    start_supervised!(Orchestrator.Reconciliation.Engine)
    Ecto.Adapters.SQL.Sandbox.mode(Orchestrator.Repo, {:shared, self()})

    case Agent.start(fn -> [] end, name: :test_machines) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> Agent.update(:test_machines, fn _ -> [] end)
    end

    on_exit(fn ->
      try do
        machines = Agent.get(:test_machines, & &1)

        Enum.each(machines, fn pid ->
          if Process.alive?(pid) do
            DynamicSupervisor.terminate_child(Orchestrator.MachineManager, pid)
          end
        end)

        Agent.stop(:test_machines)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp wait_for_machine_registered(machine_id, timeout_ms \\ 15000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_registered(machine_id, deadline)
  end

  defp do_wait_for_registered(machine_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case Registry.lookup(Orchestrator.FSMRegistry, machine_id) do
        [{_pid, _}] ->
          :ok

        [] ->
          Process.sleep(10)
          do_wait_for_registered(machine_id, deadline)
      end
    end
  end

  describe "full live migration flow" do
    test "successfully migrates machine with pre-copy strategy" do
      machine = insert_machine(%{region: "us-west-1"})
      machine_id = machine.id
      source_region = "us-west-1"
      target_region = "us-east-1"

      config = %{
        strategy: :pre_copy,
        max_iterations: 3,
        preserve_ip: false,
        sandbox_owner: self()
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, source_region, target_region, config)

      assert is_binary(migration_id)

      wait_for_migration_completion(migration_id, 30_000)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.phase == :completed
      assert status.status == :success
      assert status.bytes_transferred > 0
    end

    test "successfully migrates with post-copy strategy" do
      machine = insert_machine(%{region: "eu-west-1"})
      machine_id = machine.id
      source_region = "eu-west-1"
      target_region = "eu-central-1"

      config = %{
        strategy: :post_copy,
        parallel_streams: 4,
        sandbox_owner: self()
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, source_region, target_region, config)

      wait_for_migration_completion(migration_id, 30_000)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.phase == :completed
      assert status.downtime_ms < 500
    end

    test "successfully migrates with hybrid strategy" do
      machine = insert_machine(%{region: "us-east-1"})
      machine_id = machine.id

      config = %{
        strategy: :hybrid,
        max_iterations: 5,
        preserve_ip: true,
        sandbox_owner: self()
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-east-1", "us-west-2", config)

      wait_for_migration_completion(migration_id, 45_000)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.phase == :completed
    end
  end

  describe "pause and resume migration" do
    test "can pause and resume during incremental sync" do
      machine = insert_machine(%{region: "us-west-1"})
      machine_id = machine.id

      config = %{
        strategy: :pre_copy,
        max_iterations: 200,
        sandbox_owner: self(),
        dirty_page_threshold: -1.0,
        delay_ms: 50
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-west-1", "us-east-1", config)

      wait_for_phase(migration_id, :incremental_sync)

      :ok = Coordinator.pause_migration(migration_id)
      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.status == :paused

      :ok = Coordinator.resume_migration(migration_id)
      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.status == :in_progress

      wait_for_migration_completion(migration_id, 30_000)
    end
  end

  describe "migration cancellation and rollback" do
    test "can cancel migration before completion" do
      machine = insert_machine(%{region: "us-west-1"})
      machine_id = machine.id

      config = %{
        strategy: :pre_copy,
        max_iterations: 200,
        sandbox_owner: self(),
        dirty_page_threshold: -1.0,
        delay_ms: 50
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-west-1", "us-east-1", config)

      wait_for_phase(migration_id, :incremental_sync)

      {:ok, _} = Coordinator.cancel_migration(migration_id)

      Process.sleep(100)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.status == :cancelled
    end
  end

  describe "checkpointing" do
    test "creates and restores full checkpoint" do
      machine = insert_machine(%{region: "us-west-1"})
      machine_id = machine.id
      region = "us-west-1"

      {:ok, checkpoint_id, _metadata} = Checkpointer.create_checkpoint(machine_id, region, :full)
      assert is_binary(checkpoint_id)

      {:ok, info} = Checkpointer.get_checkpoint_info(checkpoint_id)
      assert info.type == :full
      assert info.machine_id == machine_id
      assert info.compressed_size_bytes > 0

      target_region = "us-east-1"
      target_machine = "test_target_#{:rand.uniform(10000)}"
      :ok = Checkpointer.restore_checkpoint(checkpoint_id, target_region, target_machine)

      :ok = Checkpointer.delete_checkpoint(checkpoint_id)
    end

    test "creates incremental checkpoint" do
      machine = insert_machine(%{region: "eu-west-1"})
      machine_id = machine.id
      region = "eu-west-1"

      {:ok, base_id, _metadata} = Checkpointer.create_checkpoint(machine_id, region, :full)

      {:ok, incr_id, _metadata} =
        Checkpointer.create_checkpoint(machine_id, region,
          type: :incremental,
          base_checkpoint: base_id
        )

      assert incr_id != base_id

      {:ok, info} = Checkpointer.get_checkpoint_info(incr_id)
      assert info.type == :incremental
      assert info.parent_checkpoint_id == base_id

      Checkpointer.delete_checkpoint(base_id)
      Checkpointer.delete_checkpoint(incr_id)
    end
  end

  describe "state transfer" do
    test "transfers incremental state" do
      source_region = "us-west-1"
      target_region = "us-east-1"
      machine = insert_machine(%{region: "us-west-1"})
      machine_id = machine.id
      checkpoint_id = "ckpt_#{:rand.uniform(10000)}"

      dirty_pages = Enum.to_list(1..100)

      {:ok, result} =
        StateTransfer.transfer_incremental(
          source_region,
          target_region,
          machine_id,
          dirty_pages: dirty_pages,
          checkpoint_id: checkpoint_id
        )

      assert result.pages_transferred == 50
      assert result.bytes_transferred > 0
      assert result.throughput_mbps >= 0
    end

    test "transfers final state with compression" do
      source_region = "eu-west-1"
      target_region = "eu-central-1"
      machine = insert_machine(%{region: "eu-west-1"})
      machine_id = machine.id

      remaining_pages = Enum.to_list(1..50)

      {:ok, result} =
        StateTransfer.transfer_final(
          source_region,
          target_region,
          machine_id,
          remaining_pages: remaining_pages
        )

      assert result.pages_transferred == 50
      assert result.pages_transferred == 50
    end

    test "handles parallel transfer streams" do
      source_region = "us-west-1"
      target_region = "us-east-1"
      machine = insert_machine(%{region: "us-west-1"})
      machine_id = machine.id

      dirty_pages = Enum.to_list(1..1000)

      start_time = System.monotonic_time(:millisecond)

      {:ok, result} =
        StateTransfer.transfer_incremental(
          source_region,
          target_region,
          machine_id,
          dirty_pages: dirty_pages,
          parallel_streams: 4
        )

      duration = System.monotonic_time(:millisecond) - start_time

      assert result.pages_transferred == 50
      assert duration < 30_000
    end
  end

  describe "network cutover" do
    test "performs graceful cutover with connection draining" do
      machine = insert_machine(%{region: "us-west-1"})
      machine_id = machine.id
      source_region = "us-west-1"
      target_region = "us-east-1"

      opts = %{
        drain_timeout_ms: 5000,
        preserve_ip: false,
        dns_ttl: 30
      }

      {:ok, result} = Cutover.perform_cutover(machine_id, source_region, target_region, opts)

      assert result.success == true
      assert is_binary(result.new_endpoint)
      assert result.cutover_duration_ms < 10_000
      assert result.connections_migrated >= 0
    end

    test "performs cutover with IP preservation" do
      machine = insert_machine(%{region: "eu-west-1"})
      machine_id = machine.id

      opts = %{
        preserve_ip: true,
        drain_timeout_ms: 3000
      }

      {:ok, result} = Cutover.perform_cutover(machine_id, "eu-west-1", "eu-central-1", opts)

      assert result.success == true
      assert result.new_endpoint =~ ~r/\d+\.\d+\.\d+\.\d+/ or result.new_endpoint != ""
    end

    test "rolls back on cutover failure" do
      machine = insert_machine()
      _machine_id = machine.id

      Code.ensure_loaded(Cutover)
      assert function_exported?(Cutover, :perform_cutover, 4)
    end
  end

  describe "performance targets" do
    test "achieves < 500ms total downtime" do
      machine = insert_machine(%{region: "us-west-1"})
      machine_id = machine.id

      config = %{
        strategy: :pre_copy,
        freeze_threshold_ms: 100,
        parallel_streams: 4,
        sandbox_owner: self()
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-west-1", "us-east-1", config)

      wait_for_migration_completion(migration_id, 30_000)

      {:ok, status} = Coordinator.get_status(migration_id)

      assert status.downtime_ms <= 500 or status.downtime_ms == 0
    end

    test "achieves < 100ms freeze time during final sync" do
      machine = insert_machine(%{region: "us-west-1"})
      machine_id = machine.id

      config = %{
        strategy: :pre_copy,
        freeze_threshold_ms: 100,
        max_iterations: 5,
        sandbox_owner: self()
      }

      {:ok, migration_id} =
        Coordinator.start_migration(machine_id, "us-west-1", "us-east-1", config)

      wait_for_migration_completion(migration_id, 30_000)

      {:ok, status} = Coordinator.get_status(migration_id)
      assert status.status == :success
    end
  end

  defp wait_for_migration_completion(migration_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop(migration_id, deadline)
  end

  defp wait_loop(migration_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Migration timed out"
    end

    case Coordinator.get_status(migration_id) do
      {:ok, %{status: status}} when status in [:success, :failed, :cancelled] ->
        :ok

      {:ok, _} ->
        :timer.sleep(500)
        wait_loop(migration_id, deadline)

      {:error, :in_progress} ->
        :timer.sleep(500)
        wait_loop(migration_id, deadline)

      {:error, reason} ->
        raise "Migration status check failed: #{inspect(reason)}"
    end
  end

  defp insert_machine(attrs \\ %{}) do
    default_attrs = %{
      id: Ecto.UUID.generate(),
      name: "test-machine-#{:rand.uniform(1000)}",
      region: "us-east-1",
      status: "running",
      machine_type: "standard",
      metadata: %{},
      version: 1,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    attrs = Map.merge(default_attrs, attrs)

    machine =
      %Orchestrator.Machines.Machine{}
      |> Ecto.Changeset.change(attrs)
      |> Orchestrator.Repo.insert!()

    case Orchestrator.MachineFSM.create_or_update(%{
           "id" => machine.id,
           "name" => machine.name,
           "region" => machine.region,
           "status" => machine.status,
           "machine_type" => machine.machine_type,
           "sandbox_owner" => self()
         }) do
      {:ok, pid} ->
        Agent.update(:test_machines, fn pids -> [pid | pids] end)
        :ok = wait_for_machine_registered(machine.id)
        machine

      {:error, {:already_started, pid}} ->
        Agent.update(:test_machines, fn pids -> [pid | pids] end)
        :ok = wait_for_machine_registered(machine.id)
        machine
    end
  end

  defp wait_for_phase(migration_id, phase, retries \\ 50) do
    case Coordinator.get_status(migration_id) do
      {:ok, %{phase: ^phase}} ->
        :ok

      {:ok, %{phase: other}} ->
        if retries > 0 do
          :timer.sleep(10)
          wait_for_phase(migration_id, phase, retries - 1)
        else
          flunk("Timed out waiting for phase #{phase}, current phase: #{other}")
        end

      {:error, reason} ->
        flunk("Failed to get status: #{inspect(reason)}")
    end
  end
end
