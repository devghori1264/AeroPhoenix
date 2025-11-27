defmodule Orchestrator.MachineActor.Examples do
  alias Orchestrator.MachineActor
  alias Orchestrator.MachineActor.Supervisor

  def lifecycle_example do
    machine_id = "m_example_#{:rand.uniform(10000)}"

    {:ok, pid} =
      Supervisor.start_machine(
        id: machine_id,
        region: "us-east-1",
        image: "myapp/web:v2.3.1",
        size: %{cpu_count: 2, memory_mb: 2048},
        capabilities: [:start, :stop, :migrate, :restart]
      )

    IO.puts("Machine created: #{machine_id}")

    case MachineActor.transition(pid, :start) do
      {:ok, result} ->
        IO.puts("Transition #{result.from} -> #{result.to} completed in #{result.duration_ms}ms")

      {:error, reason} ->
        IO.puts("Start failed: #{inspect(reason)}")
    end

    Process.sleep(200)

    {:ok, state} = MachineActor.get_state(pid)

    IO.inspect(state,
      label: "Current State",
      pretty: true
    )

    case MachineActor.transition(pid, :migrate, target_region: "eu-west-1") do
      {:ok, _} ->
        IO.puts("Migration started")

      {:error, reason} ->
        IO.puts("Migration failed: #{inspect(reason)}")
    end

    Process.sleep(300)

    {:ok, history} = MachineActor.get_history(pid, limit: 10)
    IO.puts("\nTransition History:")

    Enum.each(history, fn entry ->
      IO.puts("  #{entry.timestamp} | #{entry.from_state} -> #{entry.to_state} | #{entry.status}")
    end)

    {:ok, _} = MachineActor.transition(pid, :stop)
    Process.sleep(100)

    :ok = Supervisor.stop_machine(machine_id)
    IO.puts("\nMachine shut down successfully")
  end

  def crash_recovery_example do
    machine_id = "m_crash_test_#{:rand.uniform(10000)}"

    {:ok, pid} =
      Supervisor.start_machine(
        id: machine_id,
        region: "us-west-2",
        image: "test/resilient:v1.0.0"
      )

    {:ok, _} = MachineActor.transition(pid, :start)
    Process.sleep(200)

    {:ok, state_before_crash} = MachineActor.get_state(pid)
    IO.puts("State before crash: #{state_before_crash.state}")
    IO.puts("Stats before crash: #{state_before_crash.stats.transitions} transitions")

    IO.puts("\n💥 Simulating crash...")
    Process.exit(pid, :kill)
    Process.sleep(100)

    IO.puts("🔄 Recovering from crash...")
    {:ok, new_pid} = Supervisor.restart_machine(machine_id)

    {:ok, state_after_recovery} = MachineActor.get_state(new_pid)
    IO.puts("State after recovery: #{state_after_recovery.state}")
    IO.puts("Stats after recovery: #{state_after_recovery.stats.transitions} transitions")

    if state_before_crash.state == state_after_recovery.state do
      IO.puts("\n✅ State successfully recovered from SQLite!")
    else
      IO.puts("\n❌ State mismatch! Recovery failed.")
    end

    :ok = Supervisor.stop_machine(machine_id)
  end

  def concurrent_operations_example do
    machine_id = "m_concurrent_#{:rand.uniform(10000)}"

    {:ok, pid} =
      Supervisor.start_machine(
        id: machine_id,
        region: "us-east-1"
      )

    {:ok, _} = MachineActor.transition(pid, :start)
    Process.sleep(200)

    IO.puts("Testing concurrent operations...")

    task1 =
      Task.async(fn ->
        result = MachineActor.transition(pid, :migrate, target_region: "eu-west-1")
        IO.puts("Task 1 (migrate): #{inspect(result)}")
        result
      end)

    Process.sleep(10)

    task2 =
      Task.async(fn ->
        result = MachineActor.transition(pid, :stop)
        IO.puts("Task 2 (stop): #{inspect(result)}")
        result
      end)

    result1 = Task.await(task1, 10_000)
    result2 = Task.await(task2, 10_000)

    case {result1, result2} do
      {{:ok, _}, {:error, {:locked_by_operation, op_id}}} ->
        IO.puts("\n✅ Operation lock worked! Second operation blocked by #{op_id}")

      _ ->
        IO.puts("\n❌ Unexpected result pattern")
    end

    :ok = Supervisor.stop_machine(machine_id)
  end

  def capability_restriction_example do
    machine_id = "m_restricted_#{:rand.uniform(10000)}"

    {:ok, pid} =
      Supervisor.start_machine(
        id: machine_id,
        region: "us-east-1",
        capabilities: [:start, :stop]
      )

    IO.puts("Machine created with capabilities: [:start, :stop]")

    {:ok, _} = MachineActor.transition(pid, :start)
    IO.puts("✅ Start allowed")

    Process.sleep(200)

    {:ok, _} = MachineActor.transition(pid, :stop)
    IO.puts("✅ Stop allowed")

    Process.sleep(100)

    case MachineActor.transition(pid, :migrate, target_region: "eu-west-1") do
      {:error, {:missing_capability, :migrate}} ->
        IO.puts("❌ Migration blocked (missing capability)")

      {:ok, _} ->
        IO.puts("⚠️  Migration should have been blocked!")
    end

    :ok = Supervisor.stop_machine(machine_id)
  end

  def monitoring_example do
    :telemetry.attach(
      "machine-actor-example",
      [:machine_actor, :transition, :completed],
      fn event_name, measurements, metadata, _config ->
        IO.puts(
          "[TELEMETRY] #{inspect(event_name)} | " <>
            "Duration: #{measurements.duration_ms}ms | " <>
            "Machine: #{metadata.id} | " <>
            "#{metadata.from} -> #{metadata.to}"
        )
      end,
      nil
    )

    machine_id = "m_monitor_#{:rand.uniform(10000)}"

    {:ok, pid} =
      Supervisor.start_machine(
        id: machine_id,
        region: "us-east-1"
      )

    {:ok, _} = MachineActor.transition(pid, :start)
    Process.sleep(200)

    {:ok, _} = MachineActor.transition(pid, :suspend)
    Process.sleep(150)

    {:ok, _} = MachineActor.transition(pid, :resume)
    Process.sleep(200)

    {:ok, _} = MachineActor.transition(pid, :stop)
    Process.sleep(100)

    {:ok, state} = MachineActor.get_state(pid)

    IO.puts("\n📊 Machine Statistics:")
    IO.puts("  Total transitions: #{state.stats.transitions}")
    IO.puts("  Average duration: #{Float.round(state.stats.avg_transition_ms, 2)}ms")
    IO.puts("  Errors: #{state.stats.errors}")

    :telemetry.detach("machine-actor-example")
    :ok = Supervisor.stop_machine(machine_id)
  end

  def bulk_management_example do
    IO.puts("Creating 10 machines...")

    machine_ids =
      Enum.map(1..10, fn i ->
        id = "m_bulk_#{i}_#{:rand.uniform(1000)}"

        {:ok, _pid} =
          Supervisor.start_machine(
            id: id,
            region: Enum.random(["us-east-1", "us-west-2", "eu-west-1"])
          )

        id
      end)

    IO.puts("✅ Created #{length(machine_ids)} machines")

    all_machines = Supervisor.list_machines()
    IO.puts("Total machines running: #{length(all_machines)}")

    IO.puts("\nStarting all machines...")

    machine_ids
    |> Enum.map(fn id ->
      Task.async(fn ->
        {:ok, pid} = Supervisor.find_machine(id)
        MachineActor.transition(pid, :start)
      end)
    end)
    |> Task.await_many(10_000)

    Process.sleep(300)

    IO.puts("\nMachine States:")

    Enum.each(machine_ids, fn id ->
      {:ok, pid} = Supervisor.find_machine(id)
      {:ok, state} = MachineActor.get_state(pid)
      IO.puts("  #{id}: #{state.state} (#{state.region})")
    end)

    IO.puts("\nCleaning up...")

    Enum.each(machine_ids, fn id ->
      Supervisor.stop_machine(id)
    end)

    IO.puts("✅ Cleanup complete")
  end

  def run_all do
    IO.puts("=" <> String.duplicate("=", 79))
    IO.puts("MachineActor Examples")
    IO.puts("=" <> String.duplicate("=", 79))

    IO.puts("\n[Example 1] Complete Lifecycle")
    IO.puts("-" <> String.duplicate("-", 79))
    lifecycle_example()

    IO.puts("\n\n[Example 2] Crash Recovery")
    IO.puts("-" <> String.duplicate("-", 79))
    crash_recovery_example()

    IO.puts("\n\n[Example 3] Concurrent Operations")
    IO.puts("-" <> String.duplicate("-", 79))
    concurrent_operations_example()

    IO.puts("\n\n[Example 4] Capability Restrictions")
    IO.puts("-" <> String.duplicate("-", 79))
    capability_restriction_example()

    IO.puts("\n\n[Example 5] Monitoring & Telemetry")
    IO.puts("-" <> String.duplicate("-", 79))
    monitoring_example()

    IO.puts("\n\n[Example 6] Bulk Management")
    IO.puts("-" <> String.duplicate("-", 79))
    bulk_management_example()

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("All examples completed!")
  end
end
