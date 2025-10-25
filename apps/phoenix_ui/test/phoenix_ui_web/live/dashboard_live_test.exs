defmodule PhoenixUiWeb.DashboardLiveTest do
  use PhoenixUiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias PhoenixUi.PubSub

  describe "Dashboard UI" do
    test "renders dashboard and handles machine creation", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/dashboard")
      assert html =~ "AeroPhoenix"
      assert html =~ "Dashboard"

      assert has_element?(view, "form[phx-submit='create']")
      assert has_element?(view, "input[name='name']")
      assert has_element?(view, "#topology-root")
    end

    test "reacts to machine pubsub updates", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      initial_html = render(view)
      assert initial_html =~ "AeroPhoenix"

      machine = %{
        "id" => "m-123",
        "name" => "svc-demo",
        "region" => "eu-west",
        "status" => "running",
        "cpu" => 3.2,
        "memory_mb" => 512,
        "latency_ms" => 11
      }

      Phoenix.PubSub.broadcast(PubSub, "phoenix:machines", {:machine_update, machine})
      :timer.sleep(50)

      html = render(view)
      assert html =~ "AeroPhoenix"
      assert html =~ "Dashboard"
    end

    test "handles copy-cli event gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      render_click(view, "copy-cli", %{"cmd" => "flyctl deploy"})
      assert render(view) =~ "AeroPhoenix"
    end
  end
end
