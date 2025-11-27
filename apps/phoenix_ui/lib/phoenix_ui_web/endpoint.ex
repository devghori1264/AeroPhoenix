defmodule PhoenixUiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :phoenix_ui

  @session_options [
    store: :cookie,
    key: "_phoenix_ui_key",
    signing_salt: "Rqv+1Lg9",
    same_site: "Lax"
  ]

  socket("/socket", PhoenixUiWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static,
    at: "/",
    from: :phoenix_ui,
    gzip: not code_reloading?,
    only: PhoenixUiWeb.static_paths()
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(PhoenixUiWeb.Router)
end
