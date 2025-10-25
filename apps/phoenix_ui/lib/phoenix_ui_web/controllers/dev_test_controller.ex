defmodule PhoenixUiWeb.DevTestController do
  use PhoenixUiWeb, :controller

  def publish_machine(conn, params) do
    machine = %{
      "id" => params["id"] || "test-#{:rand.uniform(1000)}",
      "name" => params["name"] || "test-machine",
      "region" => params["region"] || "us-east",
      "status" => params["status"] || "running",
      "cpu" => params["cpu"] || 0.0,
      "memory_mb" => params["memory_mb"] || 256,
      "latency_ms" => params["latency_ms"] || 10
    }

    Phoenix.PubSub.broadcast(
      PhoenixUi.PubSub,
      "phoenix:machines",
      {:machine_update, machine}
    )

    json(conn, %{ok: true, machine: machine})
  end
end
