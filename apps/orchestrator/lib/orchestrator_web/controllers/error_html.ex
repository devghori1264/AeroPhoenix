defmodule OrchestratorWeb.ErrorHTML do
  use OrchestratorWeb, :html

  embed_templates "error_html/*"

  def render("404.html", _assigns), do: "Not Found"
  def render("500.html", _assigns), do: "Internal Server Error"
end
