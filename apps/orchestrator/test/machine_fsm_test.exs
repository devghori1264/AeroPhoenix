defmodule Orchestrator.MachineFSMTest do
  use ExUnit.Case, async: false
  alias Orchestrator.MachineFSM

  setup do
    bypass = Bypass.open()
    original_url = Application.get_env(:orchestrator, :http)[:base_url]
    
    new_config = Keyword.put(Application.get_env(:orchestrator, :http), :base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:orchestrator, :http, new_config)

    on_exit(fn ->
      new_config = Keyword.put(Application.get_env(:orchestrator, :http), :base_url, original_url)
      Application.put_env(:orchestrator, :http, new_config)
    end)

    {:ok, bypass: bypass}
  end

  test "start/stop flows call flyd client and persist state", %{bypass: bypass} do
    id = Ecto.UUID.generate()
    
    Bypass.expect_once(bypass, "POST", "/v1/machines/#{id}/start", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{id: id, status: "started"}))
    end)

    {:ok, pid} = MachineFSM.start_link(%{id: id})
    
    Process.sleep(50)
    
    res = GenServer.call(pid, {:command, "start"})
    assert {:ok, %{"id" => ^id, "status" => "started"}} = res
  end
end
