defmodule Orchestrator.Metrics.HTTPEndpoint do
  use Plug.Router
  use Plug.ErrorHandler

  alias Orchestrator.Metrics.Collector

  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    metrics_text = Collector.prometheus_format()

    conn
    |> put_resp_content_type("text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, metrics_text)
  end

  get "/health" do
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)

    health = %{
      status: "ok",
      uptime_seconds: div(uptime_ms, 1000),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    body = Jason.encode!(health)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    send_resp(conn, conn.status, "Internal Server Error")
  end
end
