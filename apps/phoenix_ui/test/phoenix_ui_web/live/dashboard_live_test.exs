defmodule PhoenixUiWeb.DashboardLiveTest do
  use PhoenixUiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders dashboard and can create item", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert render(view) =~ "AeroPhoenix Dashboard"
    assert render(view) =~ "Click a machine on the map to inspect"
    assert has_element?(view, "form[phx-submit='create']")
    assert has_element?(view, "input[name='name']")
    assert has_element?(view, "select[name='region']")

    _result =
      view
      |> form("form[phx-submit='create']", %{"name" => "testapp", "region" => "us-east"})
      |> render_submit()

    assert render(view) =~ "AeroPhoenix Dashboard"
  end
end
