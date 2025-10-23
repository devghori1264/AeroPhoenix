defmodule PhoenixUiWeb.DashboardLive do
  use PhoenixUiWeb, :live_view
  require Logger

  alias PhoenixUiWeb.FlydClient

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :poll)
    regions = [
      %{name: "us-east", code: "us-east", count: 0},
      %{name: "eu-west", code: "eu-west", count: 0},
      %{name: "ap-south", code: "ap-south", count: 0}
    ]
    socket = assign(socket, regions: regions, machines: [], selected: nil, error: nil)
    {:ok, socket}
  end

  @impl true
  def handle_info(:poll, socket) do
    case FlydClient.ping() do
      {:ok, _} ->
        {:noreply, socket}
      {:error, reason} ->
        {:noreply, assign(socket, error: inspect(reason))}
    end
  end

  @impl true
  def handle_event("create", %{"name" => name, "region" => region}, socket) do
    case FlydClient.create_machine(name, region) do
      {:ok, %{"id" => id, "status" => status}} ->
        m = %{"id" => id, "name" => name, "region" => region, "status" => status}
        machines = [m | socket.assigns.machines]
        regions = Enum.map(socket.assigns.regions, fn r ->
          if r.name == region, do: Map.update(r, :count, 1, &(&1 + 1)), else: r
        end)
        push_event(socket, "topology:update", %{regions: regions, machines: machines})
        {:noreply, assign(socket, machines: machines, regions: regions)}
      {:error, _} = err ->
        {:noreply, assign(socket, error: "create failed: #{inspect(err)}")}
    end
  end

  @impl true
  def handle_event("select-machine", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.machines, fn m -> m["id"] == id end) do
      nil -> {:noreply, socket}
      m -> {:noreply, assign(socket, selected: m)}
    end
  end

  @impl true
  def handle_event("refresh-machine", %{"id" => id}, socket) do
    case FlydClient.get_machine(id) do
      {:ok, %{"id" => _rid, "status" => status}} ->
        machines = Enum.map(socket.assigns.machines, fn x ->
          if x["id"] == id, do: Map.put(x, "status", status), else: x
        end)
        {:noreply, assign(socket, machines: machines, selected: Enum.find(machines, &(&1["id"] == id)))}
      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("copy-cli", %{"cmd" => cmd}, socket) do
    push_event(socket, "copy-cli", %{cmd: cmd})
    {:noreply, socket}
  end
end
