defmodule PhoenixUiWeb.ChaosLive do
  use PhoenixUiWeb, :live_view
  alias PhoenixUiWeb.OrchestratorClient

  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :load_active)
    end

    socket =
      assign(socket,
        scenarios: default_scenarios(),
        active: [],
        status: nil,
        error: nil
      )

    {:ok, socket}
  end

  def handle_info(:load_active, socket) do
    case OrchestratorClient.get("/api/v1/chaos/active") do
      {:ok, %{"active" => active}} -> {:noreply, assign(socket, active: active)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("start", %{"scenario" => scenario}, socket) do
    case OrchestratorClient.post("/api/v1/chaos/start", scenario) do
      {:ok, %{"incident" => %{"id" => id}}} ->
        send(self(), :load_active)
        {:noreply, put_flash(socket, :info, "Chaos started #{id}")}

      {:ok, %{"id" => id}} ->
        send(self(), :load_active)
        {:noreply, put_flash(socket, :info, "Chaos started #{id}")}

      {:ok, data} ->
        send(self(), :load_active)
        {:noreply, put_flash(socket, :info, "Chaos started #{inspect(data)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("stop", %{"id" => id}, socket) do
    case OrchestratorClient.post("/api/v1/chaos/stop/#{id}", %{}) do
      {:ok, _} ->
        send(self(), :load_active)
        {:noreply, put_flash(socket, :info, "Stopped")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Stop failed")}
    end
  end

  defp default_scenarios do
    [
      %{
        "label" => "Latency Spike (Region)",
        "kind" => "latency_spike",
        "duration_ms" => 30_000,
        "severity" => 0.7
      },
      %{
        "label" => "Partition (two regions)",
        "kind" => "partition",
        "duration_ms" => 60_000,
        "severity" => 0.9
      },
      %{
        "label" => "Node Kill (single host)",
        "kind" => "node_kill",
        "duration_ms" => 20_000,
        "severity" => 1.0
      }
    ]
  end
end
