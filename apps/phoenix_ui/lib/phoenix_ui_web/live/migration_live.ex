defmodule PhoenixUiWeb.MigrationLive do
  use PhoenixUiWeb, :live_view
  alias PhoenixUiWeb.FlydClient

  def mount(_params, _session, socket) do
    {:ok, assign(socket, machine: nil, targets: [], migrating: false, progress: 0)}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case FlydClient.get_machine(id) do
      {:ok, %{"id" => _rid, "status" => status}} ->
        {:noreply, assign(socket, machine: %{"id" => id, "status" => status}, targets: default_targets())}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("migrate", %{"target" => target}, socket) do
    send(self(), {:migrate_start, target})
    {:noreply, assign(socket, migrating: true, progress: 0)}
  end

  def handle_info({:migrate_start, _target}, socket) do
    for i <- 1..10 do
      :timer.sleep(200)
      send(self(), {:migrate_tick, i * 10})
    end
    send(self(), :migrate_done)
    {:noreply, socket}
  end

  def handle_info({:migrate_tick, p}, socket) do
    {:noreply, assign(socket, progress: p)}
  end

  def handle_info(:migrate_done, socket) do
    {:noreply, assign(socket, migrating: false, progress: 100)}
  end

  defp default_targets, do: ["us-east", "eu-west", "ap-south"]
end
