defmodule PhoenixUiWeb.OAuthController do
  use PhoenixUiWeb, :controller
  require Logger

  def token(conn, params) do
    with {:ok, _grant_type} <- validate_grant_type(params),
         {:ok, machine_id} <- extract_machine_id(params),
         {:ok, region} <- extract_region(params),
         {:ok, capabilities} <- extract_capabilities(params),
         {:ok, token} <- issue_token(machine_id, region, capabilities) do
      Logger.info("Issued OAuth token",
        machine_id: machine_id,
        region: region,
        capabilities: capabilities
      )

      json(conn, %{
        access_token: token,
        token_type: "Bearer",
        expires_in: 300
      })
    else
      {:error, reason} ->
        Logger.warning("Token request failed",
          reason: reason,
          params: params
        )

        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_request",
          error_description: format_error(reason)
        })
    end
  end

  def jwks(conn, _params) do
    jwks = Orchestrator.Security.OIDCProvider.get_jwks()

    json(conn, jwks)
  end

  defp validate_grant_type(%{"grant_type" => "client_credentials"}),
    do: {:ok, :client_credentials}

  defp validate_grant_type(_), do: {:error, :unsupported_grant_type}

  defp extract_machine_id(%{"machine_id" => machine_id}) when is_binary(machine_id) do
    {:ok, machine_id}
  end

  defp extract_machine_id(_), do: {:error, :missing_machine_id}

  defp extract_region(%{"region" => region}) when is_binary(region) do
    {:ok, region}
  end

  defp extract_region(_), do: {:ok, "unknown"}

  defp extract_capabilities(%{"capabilities" => caps}) when is_list(caps) do
    capability_atoms =
      Enum.map(caps, fn cap ->
        String.to_atom(cap)
      end)

    {:ok, capability_atoms}
  end

  defp extract_capabilities(_), do: {:ok, []}

  defp issue_token(machine_id, region, capabilities) do
    Orchestrator.Security.OIDCProvider.issue_token(
      machine_id: machine_id,
      region: region,
      capabilities: capabilities
    )
  end

  defp format_error(:unsupported_grant_type),
    do: "Only 'client_credentials' grant type is supported"

  defp format_error(:missing_machine_id), do: "Missing required parameter: machine_id"
  defp format_error(reason), do: inspect(reason)
end
