defmodule OrchestratorWeb.DebuggerSocket do
  use Phoenix.Socket
  require Logger
  channel("debug:*", OrchestratorWeb.DebuggerChannel)
  @impl true
  def connect(%{"token" => token} = params, socket, _connect_info) do
    case verify_token(token) do
      {:ok, user_id} ->
        socket =
          socket
          |> assign(:user_id, user_id)
          |> assign(:machine_id, Map.get(params, "machine_id"))
          |> assign(:connected_at, DateTime.utc_now())

        Logger.info("Debugger WebSocket connected",
          user_id: user_id,
          machine_id: socket.assigns.machine_id
        )

        {:ok, socket}

      {:error, reason} ->
        Logger.warning("Debugger WebSocket connection rejected",
          reason: inspect(reason)
        )

        :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    :error
  end

  @impl true
  def id(socket) do
    "debugger_socket:#{socket.assigns.user_id}:#{socket.assigns.machine_id}"
  end

  defp verify_token(token) do
    if String.length(token) > 10 do
      {:ok, extract_user_id(token)}
    else
      {:error, :invalid_token}
    end
  end

  defp extract_user_id(_token) do
    "user_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
  end
end
