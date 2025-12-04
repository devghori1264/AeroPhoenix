defmodule Orchestrator.MachineFSMTest do
  use Orchestrator.DataCase, async: false
  alias Orchestrator.MachineFSM

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Orchestrator.Repo, {:shared, self()})
    bypass = Bypass.open()
    original_url = Application.get_env(:orchestrator, :http)[:base_url]

    new_config =
      Keyword.put(
        Application.get_env(:orchestrator, :http),
        :base_url,
        "http://localhost:#{bypass.port}"
      )

    Application.put_env(:orchestrator, :http, new_config)

    on_exit(fn ->
      new_config = Keyword.put(Application.get_env(:orchestrator, :http), :base_url, original_url)
      Application.put_env(:orchestrator, :http, new_config)
    end)

    {:ok, bypass: bypass}
  end

  test "start/stop flows call flyd client and persist state", %{bypass: _bypass} do
    id = Ecto.UUID.generate()


    {:ok, pid} = MachineFSM.start_link(%{
      id: id,
      status: "stopped",
      region: "us-east-1",
      machine_type: "shared-cpu-1x"
    })

    Process.sleep(50)

    res = TestGenServer.call(pid, {:command, "start"})
    assert {:ok, %{"id" => ^id, "status" => "started"}} = res
  end
end
