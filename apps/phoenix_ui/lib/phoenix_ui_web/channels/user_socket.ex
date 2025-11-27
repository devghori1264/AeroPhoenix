defmodule PhoenixUiWeb.UserSocket do
  use Phoenix.Socket

  channel("machine:*", PhoenixUiWeb.MachineChannel)
  channel("timeline:*", PhoenixUiWeb.TimelineChannel)

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  @impl true
  def connect(params, socket, _connect_info) do
    case authenticate(params) do
      {:ok, user_id} ->
        socket =
          socket
          |> assign(:user_id, user_id)
          |> assign(:connected_at, System.system_time(:microsecond))
          |> assign(:ip_address, get_connect_info(socket, :peer_data))

        Registry.register(PhoenixUiWeb.SocketRegistry, user_id, %{
          connected_at: socket.assigns.connected_at,
          channels: []
        })

        {:ok, socket}

      {:error, reason} ->
        :telemetry.execute(
          [:phoenix_ui, :socket, :auth_failed],
          %{count: 1},
          %{reason: reason, params: sanitize_params(params)}
        )

        :error
    end
  end

  defp authenticate(%{"token" => token}) when is_binary(token) do
    case validate_token_format(token) do
      {:ok, user_id} -> {:ok, user_id}
      :error -> {:error, :invalid_token_format}
    end
  end

  defp authenticate(_params), do: {:error, :missing_token}

  defp validate_token_format(token) do
    if String.length(token) >= 8 and String.match?(token, ~r/^[a-zA-Z0-9\-_]+$/) do
      user_id = :crypto.hash(:sha256, token) |> Base.encode16() |> String.slice(0, 16)
      {:ok, "user_#{user_id}"}
    else
      :error
    end
  end

  defp sanitize_params(params) do
    Map.drop(params, ["token", "password", "secret"])
  end

  defp get_connect_info(_socket, :peer_data) do
    %{address: {127, 0, 0, 1}, port: 50000}
  end
end
