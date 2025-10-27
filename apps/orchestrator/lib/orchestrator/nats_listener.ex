defmodule Orchestrator.NatsListener do
  use GenServer
  require Logger
  @nats_url Application.get_env(:orchestrator, :nats)[:url]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    case :gnat.start_link(%{host: @nats_url}) do
      {:ok, conn} ->
        :gnat.sub(conn, self(), "machines.events")
        :gnat.sub(conn, self(), "ui.actions")
        Logger.info("NATS connected and subscriptions set")
        {:ok, conn}
      {:error, reason} ->
        Logger.error("NATS failed to connect: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  def handle_info({:msg, %{subject: "machines.events", body: body}}, conn) do
    case Jason.decode(body) do
      {:ok, payload} ->
        handle_machine_event(payload)
      _ -> :ok
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
    |> Orchestrator.MachineEvent.changeset(%{machine_id: id, type: "nats_event", payload: payload, created_at: DateTime.utc_now()})
    |> Orchestrator.Repo.insert()
    :ok
  end

  defp handle_ui_action(%{"action" => action, "id" => id} = payload) do
    case action do
      "restart" -> call_machine_cmd(id, "stop"); :timer.sleep(300); call_machine_cmd(id, "start")
      "migrate" -> call_machine_cmd(id, "migrate", Map.get(payload, "target"))
      _ -> Logger.info("UI action ignored #{inspect(action)}")
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
