defmodule PhoenixUiWeb.LogsComponent do
  use Phoenix.LiveComponent
  import PhoenixUiWeb.CoreComponents

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       logs: [],
       filter: "",
       log_level: "all",
       page: 1,
       per_page: 100
     )}
  end

  @impl true
  def update(assigns, socket) do
    logs = assigns[:logs] || []

    filtered_logs =
      logs
      |> filter_by_level(socket.assigns.log_level)
      |> filter_by_search(socket.assigns.filter)
      |> Enum.take(socket.assigns.per_page * socket.assigns.page)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(filtered_logs: filtered_logs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card p-4 flex flex-col h-full">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-title flex items-center gap-2">
          <.icon name="hero-document-text" class="w-5 h-5 text-sky-500" /> System Logs
        </h3>

        <div class="flex items-center gap-2">
          <select
            phx-change="change-log-level"
            phx-target={@myself}
            class="text-xs px-2 py-1 rounded border border-[var(--border)] bg-[var(--surface)] text-[var(--text)]"
          >
            <option value="all" selected={@log_level == "all"}>All Levels</option>
            <option value="error" selected={@log_level == "error"}>Error</option>
            <option value="warning" selected={@log_level == "warning"}>Warning</option>
            <option value="info" selected={@log_level == "info"}>Info</option>
            <option value="debug" selected={@log_level == "debug"}>Debug</option>
          </select>

          <button
            phx-click="clear-logs"
            phx-target={@myself}
            class="text-xs btn-secondary py-1 px-3"
          >
            Clear
          </button>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto space-y-1 font-mono text-xs">
        <%= if @filtered_logs == [] do %>
          <div class="flex flex-col items-center justify-center h-full text-center py-12">
            <.icon name="hero-inbox" class="w-12 h-12 text-[var(--text-muted)] mb-3" />
            <p class="text-sm text-[var(--text-secondary)]">No logs to display</p>
          </div>
        <% else %>
          <%= for log <- @filtered_logs do %>
            <div class={[
              "p-2 rounded border-l-2 hover:bg-[var(--surface-hover)] transition-colors",
              log_border_class(log)
            ]}>
              <div class="flex items-start gap-2">
                <span class={["font-semibold", log_level_class(log)]}>
                  {log_level_label(log)}
                </span>
                <span class="text-[var(--text-muted)]">{format_timestamp(log)}</span>
                <span class="flex-1 text-[var(--text-secondary)]">{log_message(log)}</span>
              </div>
            </div>
          <% end %>

          <%= if length(@logs) > length(@filtered_logs) do %>
            <button
              phx-click="load-more"
              phx-target={@myself}
              class="w-full py-2 text-center text-sm text-violet-600 hover:text-violet-700 hover:bg-[var(--surface-hover)] rounded transition-colors"
            >
              Load more logs...
            </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("change-log-level", %{"value" => level}, socket) do
    {:noreply, assign(socket, log_level: level)}
  end

  @impl true
  def handle_event("clear-logs", _params, socket) do
    send(self(), {:clear_logs})
    {:noreply, assign(socket, logs: [], filtered_logs: [])}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    {:noreply, assign(socket, page: socket.assigns.page + 1)}
  end

  defp filter_by_level(logs, "all"), do: logs

  defp filter_by_level(logs, level) do
    Enum.filter(logs, fn log ->
      log_level = log[:level] || log["level"] || "info"
      String.downcase(to_string(log_level)) == level
    end)
  end

  defp filter_by_search(logs, ""), do: logs

  defp filter_by_search(logs, query) do
    query_lower = String.downcase(query)

    Enum.filter(logs, fn log ->
      message = log_message(log) |> String.downcase()
      String.contains?(message, query_lower)
    end)
  end

  defp log_level_label(log) do
    level = log[:level] || log["level"] || "info"

    level
    |> to_string()
    |> String.upcase()
    |> String.pad_trailing(5)
  end

  defp log_level_class(log) do
    level = log[:level] || log["level"] || "info"

    case String.downcase(to_string(level)) do
      "error" -> "text-rose-600"
      "warning" -> "text-amber-600"
      "info" -> "text-sky-600"
      "debug" -> "text-gray-600"
      _ -> "text-[var(--text-secondary)]"
    end
  end

  defp log_border_class(log) do
    level = log[:level] || log["level"] || "info"

    case String.downcase(to_string(level)) do
      "error" -> "border-rose-500 bg-rose-500/5"
      "warning" -> "border-amber-500 bg-amber-500/5"
      "info" -> "border-sky-500 bg-sky-500/5"
      "debug" -> "border-gray-500 bg-gray-500/5"
      _ -> "border-[var(--border)]"
    end
  end

  defp log_message(log) do
    log[:message] || log["message"] || log[:msg] || log["msg"] || "No message"
  end

  defp format_timestamp(log) do
    ts = log[:timestamp] || log["timestamp"] || log[:ts] || log["ts"]

    case ts do
      nil ->
        ""

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
          _ -> String.slice(ts, 0, 8)
        end

      %DateTime{} = dt ->
        Calendar.strftime(dt, "%H:%M:%S")

      _ ->
        ""
    end
  end
end
