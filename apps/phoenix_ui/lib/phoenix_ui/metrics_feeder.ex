defmodule PhoenixUi.MetricsFeeder do
  use GenServer
  require Logger
  @interval 1_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    schedule()
    {:ok, state}
  end

  def handle_info(:tick, state) do
    case PhoenixUiWeb.OrchestratorClient.list_machines() do
      {:ok, machines} when is_list(machines) ->
        Enum.each(machines, fn m ->
          id = m["id"]
          sample = %{ts: DateTime.utc_now(), cpu: :rand.uniform() * 100, latency: 50 + :rand.uniform(200)}
          PhoenixUi.Machines.add_metric(id, sample)
          Phoenix.PubSub.broadcast(PhoenixUi.PubSub, "phoenix:metrics", {:metric_sample, id, sample})
        end)
      _ -> :ok
    end
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :tick, @interval)
end
