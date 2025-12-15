defmodule Orchestrator.ManagerTest do
  use Orchestrator.DataCase, async: false
  alias Orchestrator.{Repo, Manager, Machines.Machine}

  setup do
    :ok
  end

  test "create machine persists and calls remote" do
    bypass = Bypass.open(port: 8081)
    
    # Override region endpoints to point to the local Bypass instance
    original_endpoints = Application.get_env(:orchestrator, :region_endpoints)
    Application.put_env(:orchestrator, :region_endpoints, %{"eu-west-1" => "http://localhost:8081"})

    on_exit(fn ->
      if original_endpoints do
        Application.put_env(:orchestrator, :region_endpoints, original_endpoints)
      else
        Application.delete_env(:orchestrator, :region_endpoints)
      end
    end)

    Bypass.expect(bypass, "POST", "/create", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      {:ok, params} = Jason.decode(body)

      response = %{
        "id" => "remote-machine-id-#{:rand.uniform(1000)}",
        "status" => "running",
        "name" => params["name"],
        "region" => params["region"]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    {:ok, machine} = Manager.create_machine("web", "eu-west-1", "standard")
    assert machine.name == "web"
    assert machine.machine_type == "standard"
    assert machine.status in ["pending", "running"]
    m = Repo.get(Machine, machine.id)
    assert is_map(m.metadata)
    assert Map.has_key?(m.metadata, "remote_id")
  end

  test "predictor records samples and suggests migration when high" do
    id = Ecto.UUID.generate()
    Enum.each([200, 220, 210, 230, 240], fn v -> Orchestrator.Predictor.record_sample(id, v) end)
    assert {:migrate, _} = Orchestrator.Predictor.should_migrate?(id)
  end
end
