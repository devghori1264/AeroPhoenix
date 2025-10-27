defmodule PhoenixUiWeb.NatsClient do
  use GenServer
  require Logger

  @nats_url System.get_env("NATS_URL") || "nats://localhost:4222"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def publish(subject, payload) when is_binary(subject) and is_map(payload) do
    GenServer.call(__MODULE__, {:publish, subject, payload})
  end

  def init(_) do
    try do
      case :gnat.start_link(%{host: @nats_url}) do
        {:ok, conn} ->
          Process.monitor(conn)
          Logger.info("NATS client connected successfully")
          {:ok, conn}
        {:error, reason} ->
          Logger.warning("NATS connect failed: #{inspect(reason)}, will retry")
          schedule_reconnect()
          {:ok, nil}
      end
    rescue
      UndefinedFunctionError ->
        Logger.warning("NATS client library (gnat) not available, running without NATS support")
        {:ok, nil}
    end
  end

  def handle_call({:publish, subject, payload}, _from, conn) do
    case conn do
      nil ->
        {:reply, {:error, :nats_unavailable}, conn}
      pid ->
        try do
          :ok = :gnat.pub(pid, subject, Jason.encode!(payload))
          {:reply, :ok, conn}
        rescue
          UndefinedFunctionError ->
            {:reply, {:error, :gnat_not_loaded}, conn}
        end
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, _state) do
    Logger.error("NATS connection down: #{inspect(reason)}; will attempt reconnect")
    schedule_reconnect()
    {:noreply, nil}
  end

  def handle_info(:reconnect, _state) do
    try do
      case :gnat.start_link(%{host: @nats_url}) do
        {:ok, conn} -> 
          Logger.info("NATS client reconnected")
          {:noreply, conn}
        {:error, _} -> 
          schedule_reconnect()
          {:noreply, nil}
      end
    rescue
      UndefinedFunctionError ->
        {:noreply, nil}
    end
  end
  defp schedule_reconnect, do: Process.send_after(self(), :reconnect, 5_000)
end
