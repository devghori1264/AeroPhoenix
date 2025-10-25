defmodule PhoenixUiWeb.MetricsChartComponent do
  use PhoenixUiWeb, :live_component
  alias PhoenixUi.Machines

  @impl true
  def mount(socket), do: {:ok, socket}

  @impl true
  def update(%{machine_id: id} = assigns, socket) do
    metrics =
      id
      |> Machines.metrics_snapshot()
      |> List.wrap()

    {:ok, assign(socket, assigns |> Map.put(:metrics, metrics))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full h-48">
      <canvas
        id={"metrics-canvas-#{@machine_id}"}
        phx-hook="MetricsChartHook"
        data-machine-id={@machine_id}
        width="400"
        height="200"
        class="rounded bg-slate-900/50">
      </canvas>
    </div>
    """
  end
end
