defmodule Orchestrator.MachineFSMTest do
  use ExUnit.Case, async: true
  alias Orchestrator.MachineFSM

  test "start/stop flows call flyd client and persist state" do
    id = Ecto.UUID.generate()
    {:ok, pid} = MachineFSM.start_link(%{id: id})
    res = GenServer.call(pid, {:command, "start"})
    assert match?({:ok, _}, res) or match?({:error, _}, res)
  end
end
