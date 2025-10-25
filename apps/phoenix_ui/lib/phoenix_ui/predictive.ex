defmodule PhoenixUi.Predictive do
  use GenServer
  require Logger

  @topic "phoenix:predictions"
  @interval_ms 5_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def latest do
    GenServer.call(__MODULE__, :latest)
  end

  def init(_state) do
    schedule()
    {:ok, %{latest: nil}}
  end

  def handle_info(:tick, state) do
    recs = generate_mock_recommendations()
    Phoenix.PubSub.broadcast(PhoenixUi.PubSub, @topic, {:predictions, recs})
    schedule()
    {:noreply, %{state | latest: recs}}
  end

  def handle_call(:latest, _from, state), do: {:reply, state.latest, state}

  defp schedule, do: Process.send_after(self(), :tick, @interval_ms)

  defp generate_mock_recommendations do
    [
      %{"message" => "Region eu-west CPU spiking — consider pre-warming 2 machines", "score" => 0.91},
      %{"message" => "Latency trend rising between us-east and ap-south", "score" => 0.72}
    ]
  end
end
