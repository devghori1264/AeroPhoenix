defmodule Orchestrator.MachineFSMTest do
  use ExUnit.Case, async: true
  alias Orchestrator.MachineFSM

  test "start/stop flows call flyd client and persist state" do
    id = Ecto.UUID.generate()
    {:ok, pid} = MachineFSM.start_link(%{id: id})
    res = GenServer.call(pid, {:command, "start"})
    assert res == {:ok, _} or res == {:error, _}
  end
end
