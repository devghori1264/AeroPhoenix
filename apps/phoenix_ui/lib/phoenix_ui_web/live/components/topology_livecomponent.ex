defmodule PhoenixUiWeb.TopologyLiveComponent do
  use PhoenixUiWeb, :live_component

  def render(assigns) do
    ~H"""
    <div
      id="topology-root"
      phx-hook="TopologyHook"
      data-topology={Jason.encode!(@topology)}
      class="topo-container w-full h-80"
    >
      <svg id="topo-svg" class="w-full h-80"></svg>
    </div>
    """
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end
end
