defmodule Orchestrator.ManagerTest do
  use ExUnit.Case, async: false
  alias Orchestrator.{Repo, Manager, Machine}

  setup_all do
    :ok
  end

  test "create machine persists and calls remote" do
    {:ok, machine} = Manager.create_machine("web", "eu")
    assert machine.name == "web"
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
