defmodule Orchestrator.ChaosEngine do
  use GenServer
  require Logger
  alias Orchestrator.Repo
  alias Orchestrator.ChaosIncident
  @nats_topic "chaos.commands"
  @net_sim_url Application.compile_env(:orchestrator, [:net_sim, :url], "http://localhost:7070")

  @type scenario :: %{
          kind: String.t(),
          target: String.t() | nil,
          duration_ms: non_neg_integer(),
          severity: float()
        }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_heartbeat()
    {:ok, %{active: %{}, seq: 0}}
  end

  def start_scenario(scenario) when is_map(scenario) do
    GenServer.call(__MODULE__, {:start, scenario})
  end

  def stop_scenario(incident_id) do
    GenServer.call(__MODULE__, {:stop, incident_id})
  end

  def list_active, do: GenServer.call(__MODULE__, :list)

  @impl true
  def handle_call({:start, scenario}, _from, state) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    attrs = %{
      id: id,
      kind: scenario["kind"] || scenario[:kind],
      target: scenario["target"],
      severity: scenario["severity"] || 0.5,
      payload: scenario["payload"] || %{},
      started_at: now
    }

    case %ChaosIncident{} |> ChaosIncident.changeset(attrs) |> Repo.insert() do
      {:ok, incident} ->
        Task.start(fn -> dispatch_to_net_sim(incident) end)
        maybe_publish_nats(%{cmd: "start", id: incident.id, scenario: scenario})
        new_state = %{state | active: Map.put(state.active, incident.id, incident)}

        :telemetry.execute([:aerophoenix, :chaos, :incident], %{started: 1}, %{
          id: incident.id,
          kind: incident.kind
        })

        {:reply, {:ok, incident}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, incident_id}, _from, state) do
    now = DateTime.utc_now()

    case Repo.get(ChaosIncident, incident_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      incident ->
        incident = Ecto.Changeset.change(incident, ended_at: now)
        {:ok, incident} = Repo.update(incident)
        # Inform net-sim to heal
        Task.start(fn -> dispatch_to_net_sim_stop(incident) end)
        maybe_publish_nats(%{cmd: "stop", id: incident.id})
        new_active = Map.delete(state.active, incident.id)
        :telemetry.execute([:aerophoenix, :chaos, :incident], %{stopped: 1}, %{id: incident.id})
        {:reply, {:ok, incident}, %{state | active: new_active}}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.active), state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    schedule_heartbeat()
    {:noreply, state}
  end

  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, 5_000)

  defp dispatch_to_net_sim(incident) do
    url = "#{@net_sim_url}/chaos/inject"

    body = %{
      id: incident.id,
      kind: incident.kind,
      target: incident.target,
      severity: incident.severity,
      payload: incident.payload
    }

    req = Finch.build(:post, url, [{"content-type", "application/json"}], Jason.encode!(body))

    case Finch.request(req, Orchestrator.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> Logger.info("Chaos injected #{incident.id} -> #{incident.kind}")
      {:ok, %{status: s}} -> Logger.warning("Net-sim returned #{s} for chaos #{incident.id}")
      {:error, e} -> Logger.error("Chaos dispatch failed: #{inspect(e)}")
    end
  end

  defp dispatch_to_net_sim_stop(incident) do
    url = "#{@net_sim_url}/chaos/heal"
    body = %{id: incident.id}
    req = Finch.build(:post, url, [{"content-type", "application/json"}], Jason.encode!(body))

    case Finch.request(req, Orchestrator.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> Logger.info("Chaos healed #{incident.id}")
      {:error, e} -> Logger.warning("Chaos heal failed #{inspect(e)}")
    end
  end

  defp maybe_publish_nats(payload) do
    # Run NATS publishing in a separate task to prevent GenServer crashes
    Task.start(fn ->
      try do
        nats_url = Application.get_env(:orchestrator, :nats)[:url] || "nats://localhost:4222"

        case :gnat.start_link(%{host: nats_url}) do
          {:ok, conn} ->
            :gnat.pub(conn, @nats_topic, Jason.encode!(payload))
            GenServer.stop(conn)

          {:error, reason} ->
            Logger.debug("NATS publish skipped: #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.debug("NATS not available: #{inspect(e)}")
      end
    end)

    :ok
  end
end
