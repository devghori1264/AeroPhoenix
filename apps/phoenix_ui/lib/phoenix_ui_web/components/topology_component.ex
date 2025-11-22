defmodule PhoenixUiWeb.TopologyComponent do
  use Phoenix.Component

  attr :regions, :list, required: true
  attr :machines, :list, required: true
  attr :active_chaos, :list, default: []

  def render(assigns) do
    ~H"""
    <div
      id="topology-root"
      phx-hook="TopologyHook"
      data-topology={
        Jason.encode!(%{regions: @regions, machines: @machines, active_chaos: @active_chaos})
      }
      class="w-full h-[500px] bg-gray-50 dark:bg-gray-900/50 rounded-md shadow-sm p-2"
    >
      <svg id="topology-svg" class="w-full h-full"></svg>
    </div>
    """
  end
end
