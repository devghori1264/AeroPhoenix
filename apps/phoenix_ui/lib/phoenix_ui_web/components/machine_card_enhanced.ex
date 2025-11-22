defmodule PhoenixUiWeb.MachineCardEnhanced do
  use Phoenix.Component
  import PhoenixUiWeb.CoreComponents

  attr :machine, :map, required: false, default: nil
  attr :class, :string, default: ""

  def render(assigns) do
    ~H"""
    <div class={["card p-5 sm:p-6 space-y-4", @class]}>
      <div class="flex items-center justify-between">
        <h3 class="text-title gradient-text">Machine Details</h3>
        <%= if @machine do %>
          <span class={[
            "inline-flex items-center gap-2 px-3 py-1.5 rounded-full text-xs font-semibold transition-all duration-300",
            status_badge_class(@machine)
          ]}>
            <span class={["w-2 h-2 rounded-full", status_dot_class(@machine)]}></span>
            {format_status(@machine)}
          </span>
        <% end %>
      </div>

      <%= if @machine do %>
        <div class="space-y-3">
          <div class="flex justify-between items-center py-2.5 border-b border-[var(--border)] transition-colors hover:border-violet-500/50">
            <span class="text-sm text-[var(--text-muted)]">Name</span>
            <span class="text-sm font-semibold text-[var(--text)] text-mono bg-[var(--surface-hover)] px-2 py-1 rounded">
              {@machine.name || @machine["name"]}
            </span>
          </div>

          <div class="flex justify-between items-center py-2.5 border-b border-[var(--border)] transition-colors hover:border-violet-500/50">
            <span class="text-sm text-[var(--text-muted)]">ID</span>
            <span class="text-xs text-[var(--text-secondary)] text-mono bg-[var(--surface-hover)] px-2 py-1 rounded">
              {String.slice(to_string(@machine.id || @machine["id"]), 0, 12)}...
            </span>
          </div>

          <div class="flex justify-between items-center py-2.5 border-b border-[var(--border)] transition-colors hover:border-violet-500/50">
            <span class="text-sm text-[var(--text-muted)]">Region</span>
            <span class="text-sm font-medium text-[var(--text)] flex items-center gap-1.5 bg-gradient-to-r from-violet-500/10 to-cyan-500/10 px-3 py-1 rounded-full">
              <.icon name="hero-globe-americas-micro" class="w-4 h-4" />
              {@machine.region || @machine["region"]}
            </span>
          </div>

          <div class="flex justify-between items-center py-2.5 border-b border-[var(--border)] transition-colors hover:border-violet-500/50">
            <span class="text-sm text-[var(--text-muted)]">CPU Usage</span>
            <div class="flex items-center gap-2">
              <div class="w-24 h-2.5 bg-[var(--border)] rounded-full overflow-hidden shadow-inner">
                <div
                  class="h-full rounded-full transition-all duration-500 ease-out"
                  style={"width: #{cpu_percent(@machine)}%; background: linear-gradient(90deg, #{cpu_color(@machine)}, #{cpu_color_end(@machine)}); box-shadow: 0 0 8px #{cpu_color(@machine)}"}
                >
                </div>
              </div>
              <span class="text-sm font-bold text-[var(--text)] min-w-[3rem] text-right">
                {cpu_percent(@machine)}%
              </span>
            </div>
          </div>

          <div class="flex justify-between items-center py-2.5 border-b border-[var(--border)] transition-colors hover:border-violet-500/50">
            <span class="text-sm text-[var(--text-muted)]">Memory</span>
            <span class="text-sm font-semibold text-[var(--text)] bg-gradient-to-r from-cyan-500/10 to-emerald-500/10 px-3 py-1 rounded-full">
              {memory_mb(@machine)} MB
            </span>
          </div>

          <div class="flex justify-between items-center py-2.5 border-b border-[var(--border)] transition-colors hover:border-violet-500/50">
            <span class="text-sm text-[var(--text-muted)]">Latency</span>
            <span class="text-sm font-semibold text-[var(--text)] flex items-center gap-1.5">
              <.icon name="hero-signal-micro" class="w-4 h-4 text-sky-500" />
              <span class="bg-gradient-to-r from-sky-500/10 to-indigo-500/10 px-3 py-1 rounded-full">
                {latency_ms(@machine)} ms
              </span>
            </span>
          </div>

          <div class="flex justify-between items-center py-2.5">
            <span class="text-sm text-[var(--text-muted)]">Last Updated</span>
            <span class="text-xs text-[var(--text-secondary)]">
              {format_timestamp(@machine)}
            </span>
          </div>
        </div>

        <div class="flex gap-2 pt-4 border-t border-[var(--border)]">
          <button
            phx-click="refresh-machine"
            phx-value-id={@machine.id || @machine["id"]}
            class="btn-secondary flex-1 flex items-center justify-center gap-2 group"
          >
            <.icon
              name="hero-arrow-path"
              class="w-4 h-4 group-hover:rotate-180 transition-transform duration-500"
            /> Refresh
          </button>

          <button
            phx-click="copy-cli"
            phx-value-cmd={"aeropctl inspect #{@machine.name || @machine["name"]}"}
            class="btn-secondary flex-1 flex items-center justify-center gap-2 group"
          >
            <.icon
              name="hero-clipboard-document"
              class="w-4 h-4 group-hover:scale-110 transition-transform"
            /> Copy CLI
          </button>
        </div>

        <div class="flex gap-2">
          <button
            phx-click="action"
            phx-value-id={@machine.id || @machine["id"]}
            phx-value-action="stop"
            class="btn-secondary flex-1 flex items-center justify-center gap-2 hover:bg-amber-500/10 hover:border-amber-500 hover:text-amber-600 group"
          >
            <.icon
              name="hero-pause-circle"
              class="w-4 h-4 group-hover:scale-110 transition-transform"
            /> Stop
          </button>

          <button
            phx-click="action"
            phx-value-id={@machine.id || @machine["id"]}
            phx-value-action="restart"
            class="btn-secondary flex-1 flex items-center justify-center gap-2 hover:bg-sky-500/10 hover:border-sky-500 hover:text-sky-600 group"
          >
            <.icon
              name="hero-arrow-path"
              class="w-4 h-4 group-hover:rotate-180 transition-transform duration-500"
            /> Restart
          </button>
        </div>

        <div class="mt-2">
          <button
            id={"delete-btn-#{@machine.id || @machine["id"]}"}
            phx-click="delete-machine-confirm"
            phx-value-id={@machine.id || @machine["id"]}
            class="btn-secondary w-full flex items-center justify-center gap-2 hover:bg-red-500/10 hover:border-red-500 hover:text-red-600 group"
          >
            <.icon name="hero-trash" class="w-4 h-4 group-hover:scale-110 transition-transform" />
            <span id={"delete-text-#{@machine.id || @machine["id"]}"}>Delete Machine</span>
          </button>
        </div>
      <% else %>
        <div class="flex flex-col items-center justify-center py-12 text-center">
          <.icon
            name="hero-cursor-arrow-rays"
            class="w-16 h-16 text-[var(--text-muted)] mb-4 animate-pulse"
          />
          <p class="text-sm text-[var(--text-secondary)] mb-2 font-medium">No machine selected</p>
          <p class="text-xs text-[var(--text-muted)]">
            Click on a machine in the topology to view details
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_status(machine) do
    status = machine[:status] || machine["status"] || "unknown"
    status |> to_string() |> String.capitalize()
  end

  defp status_badge_class(machine) do
    status = machine[:status] || machine["status"] || "unknown"

    case to_string(status) do
      "running" -> "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
      "stopped" -> "bg-amber-500/10 text-amber-600 dark:text-amber-400"
      "migrating" -> "bg-sky-500/10 text-sky-600 dark:text-sky-400"
      "pending" -> "bg-indigo-500/10 text-indigo-600 dark:text-indigo-400"
      "terminated" -> "bg-rose-500/10 text-rose-600 dark:text-rose-400"
      _ -> "bg-gray-500/10 text-gray-600 dark:text-gray-400"
    end
  end

  defp status_dot_class(machine) do
    status = machine[:status] || machine["status"] || "unknown"

    case to_string(status) do
      "running" -> "bg-emerald-500"
      "stopped" -> "bg-amber-500"
      "migrating" -> "bg-sky-500"
      "pending" -> "bg-indigo-500"
      "terminated" -> "bg-rose-500"
      _ -> "bg-gray-500"
    end
  end

  defp cpu_percent(machine) do
    cpu = machine[:cpu] || machine["cpu"] || 0
    round(cpu)
  end

  defp cpu_color(machine) do
    cpu = cpu_percent(machine)

    cond do
      cpu >= 80 -> "var(--c-rose-500)"
      cpu >= 60 -> "var(--c-amber-500)"
      true -> "var(--c-emerald-500)"
    end
  end

  defp cpu_color_end(machine) do
    cpu = cpu_percent(machine)

    cond do
      cpu >= 80 -> "var(--c-rose-400)"
      cpu >= 60 -> "var(--c-amber-400)"
      true -> "var(--c-emerald-400)"
    end
  end

  defp memory_mb(machine) do
    mem = machine[:memory_mb] || machine["memory_mb"] || 0
    round(mem)
  end

  defp latency_ms(machine) do
    lat =
      machine[:latency] || machine[:latency_ms] || machine["latency"] || machine["latency_ms"] ||
        0

    round(lat)
  end

  defp format_timestamp(machine) do
    timestamp =
      machine[:updated_at] || machine["updated_at"] || machine[:created_at] ||
        machine["created_at"]

    case timestamp do
      nil ->
        "N/A"

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
          _ -> "N/A"
        end

      %DateTime{} = dt ->
        Calendar.strftime(dt, "%H:%M:%S")

      _ ->
        "N/A"
    end
  end
end
