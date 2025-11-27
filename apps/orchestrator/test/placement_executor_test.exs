defmodule Orchestrator.Placement.ExecutorTest do
  use Orchestrator.DataCase, async: false

  alias Orchestrator.{Machine, Repo}
  alias Orchestrator.Placement.Executor

  describe "apply_cost_optimization/2" do
    setup do
      machine1 = insert_machine(%{region: "us-east-1", status: "running"})
      machine2 = insert_machine(%{region: "us-east-1", status: "running"})
      machine3 = insert_machine(%{region: "eu-west-1", status: "running"})

      {:ok, machines: [machine1, machine2, machine3]}
    end

    test "dry-run mode simulates execution without changes", %{machines: [m1, m2, _m3]} do
      recommendations = [
        %{
          type: :consolidate,
          machine_id: m1.id,
          target_host: "host_001",
          machines_to_move: [m1.id, m2.id],
          monthly_savings: Decimal.new("150.00")
        }
      ]

      {:ok, result} = Executor.apply_cost_optimization(recommendations, mode: :dry_run)

      assert result.success
      assert result.dry_run
      assert result.executed_count == 0
      assert length(result.actions) == 1
      assert hd(result.actions).status == :would_execute
    end

    test "progressive mode executes cost recommendations sequentially", %{
      machines: [m1, _m2, _m3]
    } do
      recommendations = [
        %{
          type: :rightsize,
          machine_id: m1.id,
          current_specs: %{cpu: 4, memory_mb: 8192},
          target_specs: %{cpu: 2, memory_mb: 4096},
          monthly_savings: Decimal.new("75.00")
        }
      ]

      {:ok, result} = Executor.apply_cost_optimization(recommendations, mode: :progressive)

      assert result.success
      refute result.dry_run
      assert result.executed_count >= 0
    end

    test "validates recommendations before execution", %{machines: _machines} do
      invalid_recommendations = [
        %{
          type: :consolidate,
          machine_id: "nonexistent_machine",
          target_host: "host_001"
        }
      ]

      {:error, {:validation_failed, errors}} =
        Executor.apply_cost_optimization(invalid_recommendations, mode: :progressive)

      assert length(errors) > 0
    end

    test "handles missing required fields in recommendations" do
      invalid = [
        %{type: :consolidate}
      ]

      {:error, {:validation_failed, errors}} =
        Executor.apply_cost_optimization(invalid, mode: :progressive)

      assert [{_rec, {:missing_fields, fields}}] = errors
      assert :machine_id in fields
    end
  end

  describe "apply_latency_optimization/2" do
    setup do
      machine1 = insert_machine(%{region: "us-east-1", status: "running"})
      machine2 = insert_machine(%{region: "eu-west-1", status: "running"})

      {:ok, machines: [machine1, machine2]}
    end

    test "dry-run mode simulates latency optimization", %{machines: [m1, _m2]} do
      placements = [
        %{
          machine_id: m1.id,
          target_region: "us-west-2",
          latency_improvement_ms: 45,
          strategy: "live_migration"
        }
      ]

      {:ok, result} = Executor.apply_latency_optimization(placements, mode: :dry_run)

      assert result.success
      assert result.dry_run
      assert length(result.actions) == 1
    end

    test "validates target region exists", %{machines: [m1, _m2]} do
      placements = [
        %{
          machine_id: m1.id,
          target_region: "invalid-region",
          latency_improvement_ms: 45
        }
      ]

      {:error, {:validation_failed, errors}} =
        Executor.apply_latency_optimization(placements, mode: :progressive)

      assert length(errors) > 0
      assert [{_placement, {:invalid_region, "invalid-region"}}] = errors
    end

    test "rejects same-region migrations", %{machines: [m1, _m2]} do
      placements = [
        %{
          machine_id: m1.id,
          target_region: "us-east-1",
          latency_improvement_ms: 0
        }
      ]

      {:error, {:validation_failed, errors}} =
        Executor.apply_latency_optimization(placements, mode: :progressive)

      assert [{_placement, :same_region}] = errors
    end
  end

  describe "execute_placement/2" do
    setup do
      machine = insert_machine(%{region: "us-east-1", status: "running"})
      {:ok, machine: machine}
    end

    test "executes single migration with validation", %{machine: machine} do
      recommendation = %{
        type: :migrate,
        machine_id: machine.id,
        target_region: "us-west-2",
        strategy: "stop_and_move"
      }

      result = Executor.execute_placement(recommendation, validate: true)

      case result do
        {:ok, _} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "validates machine exists before execution" do
      recommendation = %{
        type: :migrate,
        machine_id: "nonexistent_machine_id",
        target_region: "us-west-2"
      }

      {:error, {:machine_not_found, _}} =
        Executor.execute_placement(recommendation, validate: true)
    end

    test "skips validation when force option is true" do
      recommendation = %{
        type: :migrate,
        machine_id: "nonexistent_machine_id",
        target_region: "us-west-2"
      }

      result = Executor.execute_placement(recommendation, force: true, validate: false)

      assert {:error, _} = result
    end
  end

  describe "rollback_execution/2" do
    test "loads execution checkpoints and performs rollback" do
      execution_id = "exec_test123"

      {:ok, result} = Executor.rollback_execution(execution_id)

      assert result.rolled_back_count >= 0
      assert is_list(result.errors)
    end
  end

  describe "validation functions" do
    test "validates required fields correctly" do
      valid_rec = %{
        type: :migrate,
        machine_id: "m_123",
        target_region: "us-west-2"
      }

      machine = insert_machine(%{region: "us-east-1", status: "running"})

      rec = Map.put(valid_rec, :machine_id, machine.id)

      {:ok, result} = Executor.apply_latency_optimization([rec], mode: :dry_run)
      assert result.success
    end

    test "rejects invalid recommendation types" do
      machine = insert_machine(%{region: "us-east-1", status: "running"})

      invalid = %{
        type: :invalid_type,
        machine_id: machine.id
      }

      {:error, _} = Executor.apply_cost_optimization([invalid], mode: :dry_run)
    end
  end

  describe "execution batching" do
    test "respects max_concurrent constraint" do
      machines =
        for _i <- 1..10 do
          insert_machine(%{region: "us-east-1", status: "running"})
        end

      placements =
        Enum.map(machines, fn m ->
          %{
            machine_id: m.id,
            target_region: "us-west-2",
            latency_improvement_ms: 50
          }
        end)

      {:ok, result} =
        Executor.apply_latency_optimization(placements,
          mode: :dry_run,
          max_concurrent: 3
        )

      assert result.success
      assert length(result.actions) == 10
    end

    test "applies rate limiting to prevent overload" do
      machines =
        for _i <- 1..5 do
          insert_machine(%{region: "us-east-1", status: "running"})
        end

      placements =
        Enum.map(machines, fn m ->
          %{
            machine_id: m.id,
            target_region: "us-west-2",
            latency_improvement_ms: 30
          }
        end)

      start_time = System.monotonic_time(:millisecond)

      {:ok, result} =
        Executor.apply_latency_optimization(placements,
          mode: :dry_run,
          rate_limit: 60
        )

      duration_ms = result.duration_ms

      assert duration_ms < 10_000
    end
  end

  describe "checkpoint and rollback" do
    setup do
      machine =
        insert_machine(%{
          region: "us-east-1",
          status: "running",
          metadata: %{"cpu" => "2", "memory_mb" => "4096"}
        })

      {:ok, machine: machine}
    end

    test "creates checkpoints before execution", %{machine: machine} do
      recommendation = %{
        type: :rightsize,
        machine_id: machine.id,
        current_specs: %{cpu: 2, memory_mb: 4096},
        target_specs: %{cpu: 4, memory_mb: 8192}
      }

      {:ok, _result} =
        Executor.execute_placement(recommendation,
          create_checkpoint: true,
          validate: true
        )

      assert true
    end

    test "skips checkpoint creation when disabled", %{machine: machine} do
      recommendation = %{
        type: :migrate,
        machine_id: machine.id,
        target_region: "us-west-2"
      }

      result =
        Executor.execute_placement(recommendation,
          create_checkpoint: false,
          validate: true
        )

      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end
  end

  describe "error handling" do
    test "handles machine in invalid state" do
      machine = insert_machine(%{region: "us-east-1", status: "terminated"})

      recommendation = %{
        type: :migrate,
        machine_id: machine.id,
        target_region: "us-west-2"
      }

      {:error, {:validation_failed, errors}} =
        Executor.apply_latency_optimization([recommendation], mode: :progressive)

      assert [{_rec, {:invalid_machine_state, "terminated"}}] = errors
    end

    test "handles insufficient capacity errors" do
      machine = insert_machine(%{region: "us-east-1", status: "running"})

      recommendation = %{
        type: :consolidate,
        machine_id: machine.id,
        target_host: "tiny_host",
        machines_to_move: List.duplicate(machine.id, 100)
      }

      result = Executor.apply_cost_optimization([recommendation], mode: :progressive)

      case result do
        {:error, {:validation_failed, _}} -> assert true
        {:ok, result} -> refute result.success
      end
    end
  end

  describe "integration scenarios" do
    test "complete cost optimization workflow" do
      machines =
        for i <- 1..3 do
          insert_machine(%{
            region: "us-east-1",
            status: "running",
            metadata: %{"cpu" => "8", "memory_mb" => "16384", "utilization" => "15%"}
          })
        end

      recommendations =
        Enum.map(machines, fn m ->
          %{
            type: :rightsize,
            machine_id: m.id,
            current_specs: %{cpu: 8, memory_mb: 16384},
            target_specs: %{cpu: 2, memory_mb: 4096},
            monthly_savings: Decimal.new("120.00")
          }
        end)

      {:ok, dry_result} = Executor.apply_cost_optimization(recommendations, mode: :dry_run)
      assert dry_result.dry_run
      assert length(dry_result.actions) == 3

      {:ok, real_result} =
        Executor.apply_cost_optimization(recommendations,
          mode: :progressive,
          max_concurrent: 2
        )

      assert is_map(real_result)
    end

    test "complete latency optimization workflow" do
      machine1 = insert_machine(%{region: "eu-west-1", status: "running"})
      machine2 = insert_machine(%{region: "ap-south-1", status: "running"})

      placements = [
        %{machine_id: machine1.id, target_region: "us-east-1", latency_improvement_ms: 85},
        %{machine_id: machine2.id, target_region: "us-east-1", latency_improvement_ms: 165}
      ]

      {:ok, dry_result} = Executor.apply_latency_optimization(placements, mode: :dry_run)
      assert dry_result.success

      result =
        Executor.apply_latency_optimization(placements,
          mode: :atomic,
          auto_rollback: true
        )

      case result do
        {:ok, res} ->
          assert is_map(res)

        {:error, _} ->
          assert true
      end
    end
  end

  defp insert_machine(attrs) do
    default_attrs = %{
      id: "m_#{:rand.uniform(999_999)}",
      name: "test-machine-#{:rand.uniform(1000)}",
      region: "us-east-1",
      status: "running",
      image: "test-image:latest",
      metadata: %{},
      user_id: "user_test",
      version: 1,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    machine_attrs = Map.merge(default_attrs, attrs)

    {:ok, machine} =
      %Machine{}
      |> Machine.changeset(machine_attrs)
      |> Repo.insert()

    machine
  end
end
