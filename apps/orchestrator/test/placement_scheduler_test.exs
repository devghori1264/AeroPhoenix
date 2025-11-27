defmodule Orchestrator.PlacementSchedulerTest do
  use Orchestrator.DataCase, async: false
  alias Orchestrator.Placement.Scheduler
  alias Orchestrator.{Repo, Machine}

  describe "schedule_machine/2" do
    test "schedules machine to best-fit region based on multi-objective scoring" do
      regions = ["us-east-1", "us-west-1", "eu-west-1"]

      {:ok, _pid} = Scheduler.start_link(regions: regions)

      machine_spec = %{
        cpu: 4,
        memory_gb: 16,
        disk_gb: 100,
        compliance: %{gdpr: true},
        traffic_sources: [%{region: "eu-west-1", weight: 0.8}]
      }

      {:ok, recommendation} = Scheduler.schedule_machine(machine_spec, %{})

      assert recommendation.selected_region in regions
      assert recommendation.score > 0.0
      assert recommendation.score <= 1.0

      assert recommendation.selected_region == "eu-west-1"

      assert Map.has_key?(recommendation, :resource_score)
      assert Map.has_key?(recommendation, :latency_score)
      assert Map.has_key?(recommendation, :cost_score)
      assert Map.has_key?(recommendation, :compliance_score)
    end

    test "respects compliance rules" do
      {:ok, _pid} = Scheduler.start_link(regions: ["us-east-1", "eu-west-1"])

      machine_spec = %{
        cpu: 2,
        memory_gb: 8,
        disk_gb: 50,
        compliance: %{hipaa: true}
      }

      {:ok, recommendation} = Scheduler.schedule_machine(machine_spec, %{})

      assert recommendation.selected_region in ["us-east-1", "us-west-2"]
    end

    test "handles resource constraints" do
      {:ok, _pid} = Scheduler.start_link(regions: ["us-east-1"])

      large_spec = %{
        cpu: 1000,
        memory_gb: 10000,
        disk_gb: 50000
      }

      result = Scheduler.schedule_machine(large_spec, %{})

      assert match?({:error, _}, result) or
               match?({:ok, %{warnings: [_ | _]}}, result)
    end
  end

  describe "schedule_batch/2" do
    test "optimizes placement for multiple machines globally" do
      {:ok, _pid} = Scheduler.start_link(regions: ["us-east-1", "us-west-1"])

      machines = [
        %{id: "m1", cpu: 2, memory_gb: 4, disk_gb: 20},
        %{id: "m2", cpu: 4, memory_gb: 8, disk_gb: 40},
        %{id: "m3", cpu: 2, memory_gb: 4, disk_gb: 20}
      ]

      {:ok, batch_result} = Scheduler.schedule_batch(machines, %{})

      assert length(batch_result.placements) == 3

      region_counts =
        Enum.frequencies_by(batch_result.placements, fn p -> p.region end)

      assert map_size(region_counts) > 1
    end
  end

  describe "reoptimize_placements/1" do
    test "identifies migration opportunities for cost/latency improvement" do
      {:ok, _pid} = Scheduler.start_link(regions: ["us-east-1", "us-west-1", "eu-west-1"])

      {:ok, machine1} =
        %Machine{}
        |> Machine.changeset(%{
          name: "test-machine-1",
          region: "us-west-1",
          status: "running",
          cpu: 2.0,
          memory_mb: 4096,
          metadata: %{"service" => "web"}
        })
        |> Repo.insert()

      result = Scheduler.reoptimize_placements(%{})

      assert is_list(result.recommendations)

      if length(result.recommendations) > 0 do
        rec = List.first(result.recommendations)
        assert Map.has_key?(rec, :machine_id)
        assert Map.has_key?(rec, :current_region)
        assert Map.has_key?(rec, :recommended_region)
        assert Map.has_key?(rec, :improvement_score)
      end

      Repo.delete(machine1)
    end
  end
end
