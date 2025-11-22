defmodule Orchestrator.Placement.LatencyMatrix do
  def load do
    %{
      {"us-east-1", "us-east-1"} => 0.5,
      {"us-east-1", "us-west-1"} => 65.0,
      {"us-east-1", "us-west-2"} => 70.0,
      {"us-east-1", "eu-west-1"} => 85.0,
      {"us-east-1", "ap-south-1"} => 165.0,
      {"us-west-1", "us-east-1"} => 65.0,
      {"us-west-1", "us-west-1"} => 0.5,
      {"us-west-1", "us-west-2"} => 15.0,
      {"us-west-1", "eu-west-1"} => 145.0,
      {"us-west-1", "ap-south-1"} => 180.0,
      {"us-west-2", "us-east-1"} => 70.0,
      {"us-west-2", "us-west-1"} => 15.0,
      {"us-west-2", "us-west-2"} => 0.5,
      {"us-west-2", "eu-west-1"} => 140.0,
      {"us-west-2", "ap-south-1"} => 175.0,
      {"eu-west-1", "us-east-1"} => 85.0,
      {"eu-west-1", "us-west-1"} => 145.0,
      {"eu-west-1", "us-west-2"} => 140.0,
      {"eu-west-1", "eu-west-1"} => 0.5,
      {"eu-west-1", "ap-south-1"} => 110.0,
      {"ap-south-1", "us-east-1"} => 165.0,
      {"ap-south-1", "us-west-1"} => 180.0,
      {"ap-south-1", "us-west-2"} => 175.0,
      {"ap-south-1", "eu-west-1"} => 110.0,
      {"ap-south-1", "ap-south-1"} => 0.5
    }
  end

  def get_latency(matrix, from_region, to_region) do
    Map.get(matrix, {from_region, to_region}) || Map.get(matrix, {to_region, from_region})
  end
end
