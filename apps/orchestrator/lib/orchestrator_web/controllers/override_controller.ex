defmodule OrchestratorWeb.OverrideController do
  use OrchestratorWeb, :controller
  alias Orchestrator.FeatureFlags

  action_fallback(OrchestratorWeb.FallbackController)

  def create(conn, %{"override" => override_params}) do
    with {:ok, override} <- FeatureFlags.create_override(override_params) do
      conn
      |> put_status(:created)
      |> render(:show, override: override)
    end
  end

  def delete(conn, %{"id" => id}) do
    with override when not is_nil(override) <- Repo.get(Orchestrator.FeatureFlags.Override, id),
         {:ok, _} <- FeatureFlags.delete_override(override) do
      send_resp(conn, :no_content, "")
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def show(conn, %{"flag_key" => flag_key} = params) do
    override =
      cond do
        params["user_id"] ->
          FeatureFlags.get_override(flag_key, user_id: params["user_id"])

        params["machine_id"] ->
          FeatureFlags.get_override(flag_key, machine_id: params["machine_id"])

        true ->
          nil
      end

    case override do
      nil -> {:error, :not_found}
      override -> render(conn, :show, override: override)
    end
  end
end
