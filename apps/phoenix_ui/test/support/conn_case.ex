defmodule PhoenixUiWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixUiWeb.ConnCase

      @endpoint PhoenixUiWeb.Endpoint

      use PhoenixUiWeb, :verified_routes
    end
  end

  setup _tags do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "text/html")
      |> Phoenix.ConnTest.init_test_session(%{})

    {:ok, conn: conn}
  end

  def start_session(conn, _session_opts \\ %{}) do
    conn
  end
end
