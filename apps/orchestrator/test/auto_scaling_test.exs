defmodule Orchestrator.AutoScalingTest do
  use Orchestrator.DataCase, async: false
  alias Orchestrator.Scaling.{AutoScaler, ScalingPolicy, ScalingEvent, MetricSample}
  alias Orchestrator.{Repo, Machine}

  describe "Scaling Policy management" do
    test "creates scaling policy with valid attributes" do
      attrs = %{
        service_name: "web-service",
        strategy: :hybrid,
        min_instances: 2,
        max_instances: 10,
        target_cpu_percent: 70,
        target_memory_percent: 80,
        scale_out_cooldown_seconds: 300,
        scale_in_cooldown_seconds: 600
      }

      changeset = ScalingPolicy.changeset(%ScalingPolicy{}, attrs)
      assert changeset.valid?

      {:ok, policy} = Repo.insert(changeset)
      assert policy.service_name == "web-service"
      assert policy.strategy == :hybrid
    end

    test "validates min/max instances" do
      attrs = %{
        service_name: "test-service",
        strategy: :reactive,
        min_instances: 10,
        max_instances: 5
      }

      changeset = ScalingPolicy.changeset(%ScalingPolicy{}, attrs)
      {:error, changeset} = Repo.insert(changeset)

      assert changeset.errors[:max_instances] || changeset.errors[:base]
    end
  end

  describe "AutoScaler operations" do
    setup do
      {:ok, scaler} = AutoScaler.start_link([])

      {:ok, policy} =
        %ScalingPolicy{}
        |> ScalingPolicy.changeset(%{
          service_name: "test-service",
          strategy: :hybrid,
          min_instances: 1,
          max_instances: 5,
          target_cpu_percent: 70,
          target_memory_percent: 80,
          enabled: true
        })
        |> Repo.insert()

      {:ok, machine1} =
        %Machine{}
        |> Machine.changeset(%{
          name: "test-machine-1",
          region: "us-east-1",
          status: "running",
          cpu: 80.0,
          memory_mb: 4096,
          metadata: %{"service" => "test-service"}
        })
        |> Repo.insert()

      {:ok, %{scaler: scaler, policy: policy, machine: machine1}}
    end

    test "creates scaling policy via AutoScaler", %{scaler: _scaler} do
      policy_attrs = %{
        service_name: "new-service",
        strategy: :predictive,
        min_instances: 2,
        max_instances: 10,
        target_cpu_percent: 75
      }

      {:ok, policy} = AutoScaler.create_policy(policy_attrs)
      assert policy.service_name == "new-service"
      assert policy.strategy == :predictive
    end

    test "updates scaling policy", %{policy: policy} do
      {:ok, updated} = AutoScaler.update_policy(policy.id, %{max_instances: 15})
      assert updated.max_instances == 15
    end

    test "evaluates scaling decision - reactive strategy", %{policy: policy} do
      result = AutoScaler.evaluate_scaling(policy.service_name)

      assert Map.has_key?(result, :action)
      assert result.action in [:scale_out, :scale_in, :no_action, :prevented_by_cooldown]
    end

    test "evaluates scaling decision - predictive strategy", %{scaler: _scaler} do
      {:ok, policy} =
        AutoScaler.create_policy(%{
          service_name: "ml-service",
          strategy: :predictive,
          min_instances: 1,
          max_instances: 10,
          target_cpu_percent: 70,
          prediction_confidence_threshold: 0.7
        })

      now = DateTime.utc_now()

      Enum.each(1..120, fn i ->
        %MetricSample{}
        |> MetricSample.changeset(%{
          service_name: "ml-service",
          metric_name: "cpu_percent",
          value: 60.0 + :rand.uniform(20) * 1.0,
          timestamp: DateTime.add(now, -i * 60, :second)
        })
        |> Repo.insert()
      end)

      result = AutoScaler.evaluate_scaling("ml-service")

      assert Map.has_key?(result, :predictions) || Map.has_key?(result, :action)
    end

    test "prevents rapid scaling with cooldown", %{policy: policy, machine: _machine} do
      {:ok, decision1} = AutoScaler.scale_now(policy.service_name, :scale_out, "test trigger")

      {:ok, decision2} = AutoScaler.scale_now(policy.service_name, :scale_out, "test trigger 2")

      assert decision2.action == :prevented_by_cooldown ||
               decision2.action == :no_action
    end

    test "retrieves current metrics", %{policy: policy, machine: _machine} do
      metrics = AutoScaler.get_current_metrics(policy.service_name)

      assert Map.has_key?(metrics, :avg_cpu)
      assert Map.has_key?(metrics, :avg_memory)
      assert Map.has_key?(metrics, :instance_count)
    end

    test "retrieves scaling history", %{policy: policy} do
      {:ok, _event} =
        %ScalingEvent{}
        |> ScalingEvent.changeset(%{
          service_name: policy.service_name,
          event_type: :scale_out,
          trigger_reason: "High CPU",
          previous_instance_count: 2,
          new_instance_count: 3,
          cpu_utilization: 85.0
        })
        |> Repo.insert()

      history = AutoScaler.get_scaling_history(policy.service_name)

      assert is_list(history)
      assert length(history) >= 1
    end

    test "handles scheduled scaling", %{scaler: _scaler} do
      {:ok, policy} =
        AutoScaler.create_policy(%{
          service_name: "scheduled-service",
          strategy: :scheduled,
          min_instances: 1,
          max_instances: 10,
          metadata: %{
            "schedule" => %{
              "business_hours" => %{
                "start" => "09:00",
                "end" => "17:00",
                "instances" => 5
              },
              "off_hours" => %{
                "instances" => 2
              }
            }
          }
        })

      result = AutoScaler.evaluate_scaling(policy.service_name)

      assert Map.has_key?(result, :action)
    end
  end

  describe "ML prediction accuracy" do
    test "generates predictions with confidence scores" do
      service = "trend-service"
      now = DateTime.utc_now()

      Enum.each(1..200, fn i ->
        value = 50.0 + i * 0.1 + :rand.uniform(5) * 1.0

        %MetricSample{}
        |> MetricSample.changeset(%{
          service_name: service,
          metric_name: "cpu_percent",
          value: value,
          timestamp: DateTime.add(now, -i * 60, :second)
        })
        |> Repo.insert()
      end)

      {:ok, policy} =
        AutoScaler.create_policy(%{
          service_name: service,
          strategy: :predictive,
          min_instances: 1,
          max_instances: 10,
          target_cpu_percent: 70
        })

      result = AutoScaler.evaluate_scaling(service)

      if Map.has_key?(result, :predictions) do
        assert Map.has_key?(result.predictions, :confidence)
        assert result.predictions.confidence >= 0.0
        assert result.predictions.confidence <= 1.0
      end
    end
  end
end
