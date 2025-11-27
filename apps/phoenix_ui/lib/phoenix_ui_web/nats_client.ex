defmodule PhoenixUiWeb.NatsClient do
  use GenServer
  require Logger

  @nats_url System.get_env("NATS_URL") || "nats://localhost:4222"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def publish(subject, payload) when is_binary(subject) and is_map(payload) do
    GenServer.call(__MODULE__, {:publish, subject, payload})
  end

  def init(_) do
    Process.flag(:trap_exit, true)
    send(self(), :connect)
    {:ok, nil}
  end

  def handle_info(:connect, _state) do
    try do
      uri = URI.parse(@nats_url)
      opts = %{host: uri.host, port: uri.port || 4222}

      case Gnat.start_link(opts) do
        {:ok, conn} ->
          Logger.info("NATS client connected successfully")
          {:noreply, conn}

        {:error, reason} ->
          Logger.warning("NATS connect failed: #{inspect(reason)}, will retry")
          schedule_reconnect()
          {:noreply, nil}
      end
    rescue
      e ->
        Logger.warning("NATS client error: #{inspect(e)}, running without NATS support")
        schedule_reconnect()
        {:noreply, nil}
    catch
      :exit, reason ->
        Logger.warning("NATS connect exited: #{inspect(reason)}, will retry")
        schedule_reconnect()
        {:noreply, nil}
    end
  end

  def handle_call({:publish, subject, payload}, _from, conn) do
    case conn do
      nil ->
        {:reply, {:error, :nats_unavailable}, conn}

      pid ->
        try do
          :ok = Gnat.pub(pid, subject, Jason.encode!(payload))
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

  def handle_info(:reconnect, state) do
    handle_info(:connect, state)
  end

  defp schedule_reconnect, do: Process.send_after(self(), :reconnect, 5_000)
end
