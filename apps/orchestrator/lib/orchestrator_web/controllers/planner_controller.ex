defmodule OrchestratorWeb.PlannerController do
  use OrchestratorWeb, :controller

  def recommend(conn, _params) do
    recommendations = %{
      action: "scale",
      reason: "predictive load increase",
      suggested_machines: 2,
      target_region: "us-east"
    }

    json(conn, %{recommendations: recommendations})
  end
end
