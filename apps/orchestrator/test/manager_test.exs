defmodule Orchestrator.ManagerTest do
  use ExUnit.Case, async: false
  alias Orchestrator.{Repo, Manager, Machine}

  setup_all do
    # ensure DB exists (use mix ecto.create/migrate in dev)
    :ok
  end

  test "create machine persists and calls remote" do
    # This test assumes flyd-sim http server running on localhost:8080
    {:ok, machine} = Manager.create_machine("web", "eu")
    assert machine.name == "web"
    assert machine.status in ["pending", "running"]
    # wait for reconcile to set remote id
    m = Repo.get(Machine, machine.id)
    assert is_map(m.metadata)
    assert Map.has_key?(m.metadata, "remote_id")
  end

  test "predictor records samples and suggests migration when high" do
    id = Ecto.UUID.generate()
    # record simulated high latency samples
    Enum.each([200,220,210,230,240], fn v -> Orchestrator.Predictor.record_sample(id, v) end)
    assert {:migrate, _} = Orchestrator.Predictor.should_migrate?(id)
  end
end
