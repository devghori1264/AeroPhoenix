defmodule PhoenixUiWeb.PageController do
  use PhoenixUiWeb, :controller

  def index(conn, _params) do
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} =
      HTTPoison.get("http://localhost:8080/ping", [], recv_timeout: 1000)

    render(conn, "index.html", ping: body)
  rescue
    _ -> render(conn, "index.html", ping: "no response")
  end
end
