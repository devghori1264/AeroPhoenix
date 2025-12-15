defmodule PhoenixUiWeb.Router do
  use PhoenixUiWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PhoenixUiWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/oauth", PhoenixUiWeb do
    pipe_through(:api)

    post("/token", OAuthController, :token)
    get("/.well-known/jwks.json", OAuthController, :jwks)
  end

  scope "/admin/api", PhoenixUiWeb do
    pipe_through(:api)

    post("/kill/:machine_id", AdminController, :kill_machine)
    post("/kill/global", AdminController, :global_kill)
    get("/kill/audit", AdminController, :kill_audit_log)

    post("/holodeck/spawn", AdminController, :holodeck_spawn)
    post("/holodeck/scenario", AdminController, :holodeck_scenario)
    get("/holodeck/metrics", AdminController, :holodeck_metrics)

    post("/debug/capture/:machine_id", AdminController, :start_network_capture)
    delete("/debug/capture/:machine_id", AdminController, :stop_network_capture)
    get("/debug/capture/:machine_id/stats", AdminController, :network_capture_stats)

    get("/cluster/status", AdminController, :cluster_status)
  end

  scope "/", PhoenixUiWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/dashboard", DashboardLive, :index)
    live("/dashboard/:tab", DashboardLive, :index)
    live("/debugger/:machine_id", LiveDebuggerLive, :show)
    live("/network-capture/:machine_id", NetworkCaptureLive, :show)
    live("/admin/holodeck", HolodeckLive, :index)
    get("/home", PageController, :home)
  end

  scope "/", PhoenixUiWeb do
    get("/metrics", MetricsController, :index)
  end

  scope "/", PhoenixUiWeb do
    pipe_through(:api)
    get("/health", HealthController, :index)
    get("/health/ready", HealthController, :ready)
  end

  if Mix.env() in [:dev, :test] do
    scope "/__dev", PhoenixUiWeb do
      pipe_through(:api)
      post("/publish_machine", DevTestController, :publish_machine)
    end
  end

  if Application.compile_env(:phoenix_ui, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: PhoenixUiWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
