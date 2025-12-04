defmodule Orchestrator.NatsListener do
  use GenServer
  require Logger
  @nats_url Application.compile_env(:orchestrator, [:nats, :url])

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    if Code.ensure_loaded?(Gnat) do
      try do
        if is_binary(@nats_url) do
          uri = URI.parse(@nats_url)
          opts = %{host: uri.host, port: uri.port || 4222}

          case Gnat.start_link(opts) do
            {:ok, conn} ->
              Gnat.sub(conn, self(), "machines.events")
              Gnat.sub(conn, self(), "ui.actions")
              Logger.info("NATS connected and subscriptions set")
              {:ok, conn}

            {:error, reason} ->
              Logger.warning("NATS failed to connect: #{inspect(reason)}, running without NATS")
              {:ok, nil}
          end
        else
          Logger.info("NATS URL not configured, running without NATS")
          {:ok, nil}
        end
      rescue
        e ->
          Logger.warning("NATS client error: #{inspect(e)}, running without NATS")
          {:ok, nil}
      end
    else
      Logger.warning("NATS client library (gnat) not available, running without NATS support")
      {:ok, nil}
    end
  end

  def handle_info({:msg, %{subject: "machines.events", body: body}}, conn) do
    case Jason.decode(body) do
      {:ok, payload} ->
        handle_machine_event(payload)

      _ ->
        :ok
    end

    {:noreply, conn}
  end

  def handle_info({:msg, %{subject: "ui.actions", body: body}}, conn) do
    case Jason.decode(body) do
      {:ok, payload} -> handle_ui_action(payload)
      _ -> :ok
    end

    {:noreply, conn}
  end

  defp handle_machine_event(payload) do
    id = payload["id"]
    :ok = Orchestrator.MachineManager.ensure_started(id, payload)

    %Orchestrator.MachineEvent{}
    |> Orchestrator.MachineEvent.changeset(%{
      machine_id: id,
      type: "nats_event",
      payload: payload,
      created_at: DateTime.utc_now()
    })
    |> Orchestrator.Repo.insert()

    :ok
  end

  defp handle_ui_action(%{"action" => action, "id" => id} = payload) do
    case action do
      "restart" ->
        call_machine_cmd(id, "stop")
        :timer.sleep(300)
        call_machine_cmd(id, "start")

      "migrate" ->
        call_machine_cmd(id, "migrate", Map.get(payload, "target"))

      _ ->
        Logger.info("UI action ignored #{inspect(action)}")
    end
  end

  defp call_machine_cmd(id, cmd, arg \\ nil) do
    case Registry.lookup(Orchestrator.FSMRegistry, id) do
      [{pid, _}] ->
        case cmd do
          "start" -> GenServer.call(pid, {:command, "start"})
          "stop" -> GenServer.call(pid, {:command, "stop"})
          "migrate" -> GenServer.call(pid, {:command, "migrate", arg})
        end

      [] ->
        Orchestrator.MachineManager.ensure_started(id)
        :ok
    end
  end
end
