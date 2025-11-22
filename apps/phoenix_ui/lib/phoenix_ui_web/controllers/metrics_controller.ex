defmodule PhoenixUiWeb.MetricsController do
  use PhoenixUiWeb, :controller

  def index(conn, _params) do
    text(
      conn,
      "# Phoenix UI - Metrics endpoint\n# See orchestrator:9568/metrics for application metrics\n"
    )
  end
end
