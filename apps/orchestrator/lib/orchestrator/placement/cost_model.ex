defmodule Orchestrator.Placement.CostModel do
  def load_all do
    %{
      "us-east-1" => %{
        cpu_per_core_hourly: Decimal.new("0.02"),
        memory_per_gb_hourly: Decimal.new("0.004"),
        disk_per_gb_monthly: Decimal.new("0.10"),
        network_egress_per_gb: Decimal.new("0.09")
      },
      "us-west-1" => %{
        cpu_per_core_hourly: Decimal.new("0.024"),
        memory_per_gb_hourly: Decimal.new("0.0048"),
        disk_per_gb_monthly: Decimal.new("0.12"),
        network_egress_per_gb: Decimal.new("0.09")
      },
      "us-west-2" => %{
        cpu_per_core_hourly: Decimal.new("0.022"),
        memory_per_gb_hourly: Decimal.new("0.0044"),
        disk_per_gb_monthly: Decimal.new("0.11"),
        network_egress_per_gb: Decimal.new("0.09")
      },
      "eu-west-1" => %{
        cpu_per_core_hourly: Decimal.new("0.025"),
        memory_per_gb_hourly: Decimal.new("0.005"),
        disk_per_gb_monthly: Decimal.new("0.11"),
        network_egress_per_gb: Decimal.new("0.12")
      },
      "ap-south-1" => %{
        cpu_per_core_hourly: Decimal.new("0.021"),
        memory_per_gb_hourly: Decimal.new("0.0042"),
        disk_per_gb_monthly: Decimal.new("0.09"),
        network_egress_per_gb: Decimal.new("0.11")
      }
    }
  end

  def calculate_monthly_cost(cost_model, cpu_cores, memory_gb, disk_gb) do
    hours_per_month = Decimal.new(730)

    cpu_cost =
      Decimal.mult(
        Decimal.mult(cost_model.cpu_per_core_hourly, Decimal.new(cpu_cores)),
        hours_per_month
      )

    memory_cost =
      Decimal.mult(
        Decimal.mult(cost_model.memory_per_gb_hourly, Decimal.new(memory_gb)),
        hours_per_month
      )

    disk_cost = Decimal.mult(cost_model.disk_per_gb_monthly, Decimal.new(disk_gb))

    cpu_cost
    |> Decimal.add(memory_cost)
    |> Decimal.add(disk_cost)
  end
end
