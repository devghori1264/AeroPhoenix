defmodule PhoenixUiWeb.MachineCardComponent do
  use PhoenixUiWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, loading: false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, Map.merge(socket.assigns, assigns))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"machine-#{@machine.id}"}
        class="rounded-2xl bg-slate-800 p-4 text-white shadow-md border border-slate-700
                transition-transform duration-200 hover:scale-[1.01] hover:shadow-lg">

      <div class="flex justify-between items-start">
        <div>
          <h4 class="font-semibold text-base"><%= @machine.name %></h4>
          <p class="text-xs text-gray-400"><%= @machine.region %></p>
        </div>
        <div class="flex items-center space-x-1">
          <span class={status_class(@machine.status)} aria-label={"status-#{@machine.status}"}>●</span>
          <span class="text-sm"><%= status_label(@machine.status) %></span>
        </div>
      </div>

      <div class="mt-3 text-xs space-y-1 font-mono">
        <div>CPU: <strong><%= format_number(@machine.cpu) %>%</strong></div>
        <div>MEM: <strong><%= format_number(@machine.memory_mb) %> MB</strong></div>
        <div>Latency: <strong><%= format_number(@machine.latency) %> ms</strong></div>
      </div>

      <div class="mt-4 flex flex-wrap gap-2">
        <button phx-click="action"
                phx-value-id={@machine.id}
                phx-value-action="restart"
                class="px-2 py-1 rounded bg-blue-600 text-xs hover:bg-blue-500 transition">
          Restart
        </button>
        <button phx-click="action"
                phx-value-id={@machine.id}
                phx-value-action="migrate"
                class="px-2 py-1 rounded bg-yellow-500 text-xs text-black hover:bg-yellow-400 transition">
          Migrate
        </button>
        <button phx-click="select_machine"
                phx-value-id={@machine.id}
                class="px-2 py-1 rounded bg-gray-700 text-xs hover:bg-gray-600 transition">
          Inspect
        </button>
      </div>
    </div>
    """
  end

  defp status_class(s) when is_atom(s) do
    case s do
      :running -> "text-green-400"
      :migrating -> "text-yellow-400"
      :stopped -> "text-red-400"
      _ -> "text-gray-400"
    end
  end
  defp status_class(_), do: "text-gray-400"

  defp status_label(s) when is_atom(s), do: Atom.to_string(s)
  defp status_label(s) when is_binary(s), do: s
  defp status_label(_), do: "unknown"

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n) when is_binary(n), do: n
  defp format_number(_), do: "0"
end
