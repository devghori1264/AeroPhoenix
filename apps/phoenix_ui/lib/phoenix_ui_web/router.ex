defmodule PhoenixUiWeb.Router do
  use PhoenixUiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PhoenixUiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PhoenixUiWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/dashboard", DashboardLive, :index
    get "/home", PageController, :home
  end

  scope "/metrics" do
    forward "/", TelemetryMetricsPrometheus.Plug, init_opts: [name: PhoenixUiWeb.PrometheusExporter]
  end


  if Mix.env() in [:dev, :test] do
    scope "/__dev", PhoenixUiWeb do
      pipe_through :api
      post "/publish_machine", DevTestController, :publish_machine
    end
  end

  if Application.compile_env(:phoenix_ui, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: PhoenixUiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
