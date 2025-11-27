defmodule OrchestratorWeb.FallbackController do
  use OrchestratorWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: OrchestratorWeb.ErrorHTML, json: OrchestratorWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :bad_request}) do
    conn
    |> put_status(:bad_request)
    |> put_view(html: OrchestratorWeb.ErrorHTML, json: OrchestratorWeb.ErrorJSON)
    |> render(:"400")
  end

  def call(conn, {:error, :bad_request, reason}) do
    conn
    |> put_status(:bad_request)
    |> put_view(html: OrchestratorWeb.ErrorHTML, json: OrchestratorWeb.ErrorJSON)
    |> render(:"400", reason: reason)
  end

  def call(conn, {:error, _reason}) do
    conn
    |> put_status(:internal_server_error)
    |> put_view(html: OrchestratorWeb.ErrorHTML, json: OrchestratorWeb.ErrorJSON)
    |> render(:"500")
  end
end
