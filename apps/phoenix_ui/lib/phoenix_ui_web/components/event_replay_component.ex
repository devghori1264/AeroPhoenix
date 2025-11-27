defmodule PhoenixUiWeb.EventReplayComponent do
  use PhoenixUiWeb, :live_component
  require Logger
  alias PhoenixUiWeb.OrchestratorClient

  @playback_speeds [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]
  @page_size 50

  @refresh_interval 5_000

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:loading, true)
     |> assign(:view_mode, "aggregates")
     |> assign(:aggregates, [])
     |> assign(:selected_aggregate, nil)
     |> assign(:events, [])
     |> assign(:total_events, 0)
     |> assign(:current_page, 1)
     |> assign(:reconstructed_state, nil)
     |> assign(:state_diff, nil)
     |> assign(:playback_state, :paused)
     |> assign(:playback_speeds, @playback_speeds)
     |> assign(:playback_speed, 1.0)
     |> assign(:playback_position, 0)
     |> assign(:selected_event, nil)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:correlation_trace, nil)
     |> assign(:filter_type, "all")
     |> assign(:filter_tags, [])
     |> assign(:time_range, "all")
     |> assign(:from_version, nil)
     |> assign(:to_version, nil)
     |> assign(:diff_mode, false)
     |> assign(:theme, "dark")
     |> assign(:error, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if connected?(socket) && socket.assigns.loading do
        send(self(), {:load_aggregates, socket.assigns.id})
        assign(socket, :loading, false)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_aggregate", %{"id" => aggregate_id}, socket) do
    case load_aggregate_events(aggregate_id, 1) do
      {:ok, result} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Orchestrator.PubSub, "events:#{aggregate_id}")
        end

        {:noreply,
         socket
         |> assign(:selected_aggregate, aggregate_id)
         |> assign(:view_mode, "timeline")
         |> assign(:events, result.events)
         |> assign(:total_events, result.count)
         |> assign(:current_page, 1)
         |> assign(:playback_position, 0)
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Failed to load events: #{reason}")}
    end
  end

  def handle_event("change_page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)

    case load_aggregate_events(socket.assigns.selected_aggregate, page) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:events, result.events)
         |> assign(:current_page, page)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("select_event", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    event = Enum.at(socket.assigns.events, index)

    {:noreply,
     socket
     |> assign(:selected_event, event)
     |> assign(:playback_position, index)}
  end

  def handle_event("reconstruct_state", %{"version" => version_str}, socket) do
    version = String.to_integer(version_str)
    aggregate_id = socket.assigns.selected_aggregate

    case reconstruct_state_at_version(aggregate_id, version) do
      {:ok, state} ->
        {:noreply,
         socket
         |> assign(:reconstructed_state, state)
         |> assign(:view_mode, "state_viewer")
         |> push_event("state_reconstructed", %{version: version})}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "State reconstruction failed: #{reason}")}
    end
  end

  def handle_event("compute_diff", %{"from" => from_str, "to" => to_str}, socket) do
    from_version = String.to_integer(from_str)
    to_version = String.to_integer(to_str)
    aggregate_id = socket.assigns.selected_aggregate

    case compute_state_diff(aggregate_id, from_version, to_version) do
      {:ok, diff} ->
        {:noreply,
         socket
         |> assign(:state_diff, diff)
         |> assign(:from_version, from_version)
         |> assign(:to_version, to_version)
         |> assign(:diff_mode, true)
         |> assign(:view_mode, "diff_viewer")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Diff computation failed: #{reason}")}
    end
  end

  def handle_event("search_events", %{"query" => query}, socket) do
    if String.length(query) >= 2 do
      case search_events(query) do
        {:ok, results} ->
          {:noreply,
           socket
           |> assign(:search_results, results)
           |> assign(:search_query, query)
           |> assign(:view_mode, "search_results")}

        {:error, _} ->
          {:noreply, assign(socket, :search_results, [])}
      end
    else
      {:noreply, assign(socket, :search_results, [])}
    end
  end

  def handle_event("trace_correlation", %{"correlation_id" => correlation_id}, socket) do
    case trace_correlation(correlation_id) do
      {:ok, trace} ->
        {:noreply,
         socket
         |> assign(:correlation_trace, trace)
         |> assign(:view_mode, "correlation_trace")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Correlation trace failed: #{reason}")}
    end
  end

  def handle_event("toggle_playback", _params, socket) do
    new_state =
      case socket.assigns.playback_state do
        :paused -> :playing
        :playing -> :paused
      end

    socket =
      if new_state == :playing do
        schedule_playback_tick(socket.assigns.id)
        socket
      else
        socket
      end

    {:noreply, assign(socket, :playback_state, new_state)}
  end

  def handle_event("change_playback_speed", %{"speed" => speed_str}, socket) do
    speed = String.to_float(speed_str)
    {:noreply, assign(socket, :playback_speed, speed)}
  end

  def handle_event("step_forward", _params, socket) do
    new_position = min(socket.assigns.playback_position + 1, length(socket.assigns.events) - 1)
    event = Enum.at(socket.assigns.events, new_position)

    {:noreply,
     socket
     |> assign(:playback_position, new_position)
     |> assign(:selected_event, event)}
  end

  def handle_event("step_backward", _params, socket) do
    new_position = max(socket.assigns.playback_position - 1, 0)
    event = Enum.at(socket.assigns.events, new_position)

    {:noreply,
     socket
     |> assign(:playback_position, new_position)
     |> assign(:selected_event, event)}
  end

  def handle_event("reset_playback", _params, socket) do
    {:noreply,
     socket
     |> assign(:playback_position, 0)
     |> assign(:playback_state, :paused)
     |> assign(:selected_event, List.first(socket.assigns.events))}
  end

  def handle_event("change_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("toggle_theme", _params, socket) do
    new_theme = if socket.assigns.theme == "dark", do: "light", else: "dark"
    {:noreply, assign(socket, :theme, new_theme)}
  end

  def handle_event("export_timeline", %{"format" => format}, socket) do
    Logger.info("Exporting timeline in format: #{format}")
    {:noreply, socket}
  end

  def handle_event("close_diff", _params, socket) do
    {:noreply,
     socket
     |> assign(:diff_mode, false)
     |> assign(:state_diff, nil)
     |> assign(:view_mode, "timeline")}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:view_mode, "timeline")}
  end

  def handle_event("apply_filter", %{"type" => type, "tags" => tags}, socket) do
    tag_list = if tags == "", do: [], else: String.split(tags, ",") |> Enum.map(&String.trim/1)

    case load_filtered_events(socket.assigns.selected_aggregate, type, tag_list) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:events, result.events)
         |> assign(:filter_type, type)
         |> assign(:filter_tags, tag_list)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("back_to_aggregates", _params, socket) do
    if socket.assigns.selected_aggregate do
      Phoenix.PubSub.unsubscribe(
        Orchestrator.PubSub,
        "events:#{socket.assigns.selected_aggregate}"
      )
    end

    {:noreply,
     socket
     |> assign(:view_mode, "aggregates")
     |> assign(:selected_aggregate, nil)
     |> assign(:events, [])
     |> assign(:selected_event, nil)
     |> assign(:reconstructed_state, nil)
     |> assign(:state_diff, nil)
     |> assign(:playback_state, :paused)
     |> assign(:playback_position, 0)}
  end

  def handle_info({:load_aggregates, component_id}, socket) do
    if socket.assigns.id == component_id do
      case load_aggregates() do
        {:ok, aggregates} ->
          schedule_refresh(component_id)
          {:noreply, assign(socket, :aggregates, aggregates)}

        {:error, reason} ->
          Logger.error("Failed to load aggregates: #{reason}")
          {:noreply, assign(socket, :error, "Failed to load aggregates")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:refresh_data, component_id}, socket) do
    if socket.assigns.id == component_id && socket.assigns.view_mode == "aggregates" do
      case load_aggregates() do
        {:ok, aggregates} ->
          schedule_refresh(component_id)
          {:noreply, assign(socket, :aggregates, aggregates)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:playback_tick, component_id}, socket) do
    if socket.assigns.id == component_id && socket.assigns.playback_state == :playing do
      new_position = socket.assigns.playback_position + 1

      if new_position < length(socket.assigns.events) do
        event = Enum.at(socket.assigns.events, new_position)
        delay = trunc(1000 / socket.assigns.playback_speed)
        Process.send_after(self(), {:playback_tick, component_id}, delay)

        {:noreply,
         socket
         |> assign(:playback_position, new_position)
         |> assign(:selected_event, event)}
      else
        {:noreply, assign(socket, :playback_state, :paused)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{event: "event_appended", payload: event}, socket) do
    if event.aggregate_id == socket.assigns.selected_aggregate do
      {:noreply, socket |> update(:events, &(&1 ++ [event])) |> update(:total_events, &(&1 + 1))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_aggregates do
    case OrchestratorClient.get("/api/events/aggregates") do
      {:ok, %{"aggregates" => aggregates}} ->
        {:ok, aggregates}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "Invalid response format"}
    end
  end

  defp load_aggregate_events(aggregate_id, page) do
    offset = (page - 1) * @page_size

    case OrchestratorClient.get(
           "/api/events/#{aggregate_id}?limit=#{@page_size}&offset=#{offset}"
         ) do
      {:ok, %{"events" => events, "count" => count}} ->
        {:ok, %{events: events, count: count}}

      {:ok, %{"events" => events}} ->
        {:ok, %{events: events, count: length(events)}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "Invalid response format"}
    end
  end

  defp load_filtered_events(aggregate_id, event_type, tags) do
    params =
      []
      |> maybe_add_param(event_type != "all", "event_types=#{event_type}")
      |> maybe_add_param(!Enum.empty?(tags), "tags=#{Enum.join(tags, ",")}")
      |> Enum.join("&")

    query_string = if params != "", do: "?#{params}", else: ""

    case OrchestratorClient.get("/api/events/#{aggregate_id}#{query_string}") do
      {:ok, %{"events" => events, "count" => count}} ->
        {:ok, %{events: events, count: count}}

      {:ok, %{"events" => events}} ->
        {:ok, %{events: events, count: length(events)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconstruct_state_at_version(aggregate_id, version) do
    case OrchestratorClient.post("/api/events/#{aggregate_id}/rebuild", %{version: version}) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compute_state_diff(aggregate_id, from_version, to_version) do
    case OrchestratorClient.get(
           "/api/events/#{aggregate_id}/diff?from=#{from_version}&to=#{to_version}"
         ) do
      {:ok, diff_result} ->
        {:ok, diff_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_events(query) do
    case OrchestratorClient.get("/api/events/search?q=#{URI.encode(query)}&limit=100") do
      {:ok, %{"events" => events}} ->
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp trace_correlation(correlation_id) do
    case OrchestratorClient.get("/api/events/correlation/#{correlation_id}") do
      {:ok, trace_data} ->
        {:ok, trace_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_param(list, false, _param), do: list
  defp maybe_add_param(list, true, param), do: list ++ [param]

  defp schedule_refresh(component_id) do
    Process.send_after(self(), {:refresh_data, component_id}, @refresh_interval)
  end

  defp schedule_playback_tick(component_id) do
    Process.send_after(self(), {:playback_tick, component_id}, 1000)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={"event-replay-container transition-all duration-300 #{if @theme == "light", do: "light-theme", else: ""}"}>
      <%= if @error do %>
        <div class="hud-card bg-red-500/10 border-red-500/30 mb-4">
          <div class="flex items-center gap-3">
            <.icon name="hero-exclamation-triangle" class="w-6 h-6 text-red-400" />
            <div>
              <p class="font-semibold text-red-400">Error</p>
              <p class="text-sm text-red-300">{@error}</p>
            </div>
            <button
              phx-click="back_to_aggregates"
              phx-target={@myself}
              class="ml-auto px-3 py-1 rounded bg-red-500/20 hover:bg-red-500/30 text-red-300 text-sm transition"
            >
              Dismiss
            </button>
          </div>
        </div>
      <% end %>

      <%= case @view_mode do %>
        <% "aggregates" -> %>
          {render_aggregates_list(assigns)}
        <% "timeline" -> %>
          {render_timeline_view(assigns)}
        <% "state_viewer" -> %>
          {render_state_viewer(assigns)}
        <% "diff_viewer" -> %>
          {render_diff_viewer(assigns)}
        <% "search_results" -> %>
          {render_search_results(assigns)}
        <% "correlation_trace" -> %>
          {render_correlation_trace(assigns)}
      <% end %>
    </div>
    """
  end

  defp render_aggregates_list(assigns) do
    ~H"""
    <div class="space-y-6 animate-fade-in">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-2xl font-bold text-white flex items-center gap-3">
            <div class="w-10 h-10 rounded-lg bg-indigo-500/20 flex items-center justify-center border border-indigo-500/30">
              <.icon name="hero-clock" class="w-6 h-6 text-indigo-400" />
            </div>
            Event Sourcing Replay
          </h2>
          <p class="text-slate-400 mt-1">Time-travel through your system's event history</p>
        </div>

        <div class="flex items-center gap-3">
          <div class="px-3 py-1.5 rounded-lg bg-indigo-500/10 border border-indigo-500/30">
            <span class="text-sm text-indigo-300">
              {length(@aggregates)} Aggregates
            </span>
          </div>
        </div>
      </div>

      <%= if Enum.empty?(@aggregates) do %>
        <div class="hud-card flex flex-col items-center justify-center py-16">
          <div class="w-20 h-20 rounded-full bg-slate-700/50 flex items-center justify-center mb-4">
            <.icon name="hero-inbox" class="w-10 h-10 text-slate-500" />
          </div>
          <h3 class="text-xl font-bold text-slate-300 mb-2">No Event Streams Found</h3>
          <p class="text-slate-400 text-center max-w-md">
            Event streams will appear here as your system generates events.
            Create some machines or perform actions to see events.
          </p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <%= for aggregate <- @aggregates do %>
            <div
              class="hud-card group hover:border-indigo-500/50 cursor-pointer transition-all duration-300 hover:scale-[1.02]"
              phx-click="select_aggregate"
              phx-value-id={aggregate["aggregate_id"]}
              phx-target={@myself}
            >
              <div class="flex items-start justify-between mb-4">
                <div>
                  <h3 class="font-bold text-white group-hover:text-indigo-400 transition-colors">
                    {aggregate["aggregate_type"] || "Unknown"}
                  </h3>
                  <p class="text-xs text-slate-500 font-mono mt-1">
                    {String.slice(aggregate["aggregate_id"], 0, 8)}...
                  </p>
                </div>
                <div class="px-2 py-1 rounded bg-indigo-500/20 border border-indigo-500/30">
                  <span class="text-xs text-indigo-300 font-medium">
                    v{aggregate["latest_version"] || 0}
                  </span>
                </div>
              </div>

              <div class="grid grid-cols-2 gap-3 mb-4">
                <div>
                  <p class="text-xs text-slate-500 mb-1">Events</p>
                  <p class="text-lg font-bold text-white">{aggregate["event_count"] || 0}</p>
                </div>
                <div>
                  <p class="text-xs text-slate-500 mb-1">Event Types</p>
                  <p class="text-lg font-bold text-white">{aggregate["unique_event_types"] || 0}</p>
                </div>
              </div>

              <div class="pt-3 border-t border-slate-700/50">
                <p class="text-xs text-slate-500">Last Event</p>
                <p class="text-sm text-slate-300 mt-1">
                  {format_timestamp(aggregate["last_event_at"])}
                </p>
              </div>

              <div class="mt-3 flex items-center text-indigo-400 opacity-0 group-hover:opacity-100 transition-opacity">
                <span class="text-sm font-medium">View Timeline</span>
                <.icon name="hero-arrow-right" class="w-4 h-4 ml-2" />
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_timeline_view(assigns) do
    ~H"""
    <div class="space-y-4 animate-fade-in">
      <div class="hud-card">
        <div class="flex items-center justify-between flex-wrap gap-4">
          <div class="flex items-center gap-3">
            <button
              phx-click="back_to_aggregates"
              phx-target={@myself}
              class="px-3 py-2 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition flex items-center gap-2"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" />
              <span class="text-sm">Back</span>
            </button>

            <div class="h-8 w-px bg-slate-700"></div>

            <h3 class="font-bold text-white">
              Timeline View
              <span class="text-slate-500 font-normal ml-2">({@total_events} events)</span>
            </h3>
          </div>

          <div class="flex items-center gap-2">
            <button
              phx-click="reset_playback"
              phx-target={@myself}
              class="p-2 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition"
              title="Reset"
            >
              <.icon name="hero-backward" class="w-4 h-4" />
            </button>

            <button
              phx-click="step_backward"
              phx-target={@myself}
              class="p-2 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition"
              title="Step Back"
            >
              <.icon name="hero-chevron-left" class="w-4 h-4" />
            </button>

            <button
              phx-click="toggle_playback"
              phx-target={@myself}
              class={[
                "p-2 rounded-lg transition",
                if(@playback_state == :playing,
                  do: "bg-indigo-500 text-white",
                  else: "bg-slate-700/50 hover:bg-slate-700 text-slate-300"
                )
              ]}
              title={if @playback_state == :playing, do: "Pause", else: "Play"}
            >
              <%= if @playback_state == :playing do %>
                <.icon name="hero-pause" class="w-4 h-4" />
              <% else %>
                <.icon name="hero-play" class="w-4 h-4" />
              <% end %>
            </button>

            <button
              phx-click="step_forward"
              phx-target={@myself}
              class="p-2 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition"
              title="Step Forward"
            >
              <.icon name="hero-chevron-right" class="w-4 h-4" />
            </button>

            <div class="h-8 w-px bg-slate-700 mx-2"></div>

            <select
              phx-change="change_playback_speed"
              phx-target={@myself}
              name="speed"
              class="px-3 py-2 rounded-lg bg-slate-700/50 border border-slate-600 text-slate-300 text-sm focus:outline-none focus:border-indigo-500"
            >
              <%= for speed <- @playback_speeds do %>
                <option value={speed} selected={@playback_speed == speed}>
                  {speed}x
                </option>
              <% end %>
            </select>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-12 gap-4">
        <div class="col-span-7 space-y-2 max-h-[600px] overflow-y-auto custom-scrollbar">
          <%= for {event, index} <- Enum.with_index(@events) do %>
            <div
              class={[
                "hud-card group cursor-pointer transition-all duration-200",
                if(index == @playback_position,
                  do: "border-indigo-500 bg-indigo-500/5 scale-[1.02]",
                  else: "hover:border-slate-600"
                )
              ]}
              phx-click="select_event"
              phx-value-index={index}
              phx-target={@myself}
            >
              <div class="flex items-start gap-3">
                <div class="relative flex-shrink-0">
                  <div class={[
                    "w-3 h-3 rounded-full transition-all",
                    if(index == @playback_position,
                      do: "bg-indigo-500 ring-4 ring-indigo-500/30",
                      else: "bg-slate-600 group-hover:bg-indigo-400"
                    )
                  ]}>
                  </div>
                  <%= if index < length(@events) - 1 do %>
                    <div class="absolute top-3 left-1/2 -translate-x-1/2 w-0.5 h-8 bg-slate-700">
                    </div>
                  <% end %>
                </div>

                <div class="flex-1 min-w-0">
                  <div class="flex items-center justify-between mb-2">
                    <h4 class="font-medium text-white text-sm">
                      {event["event_type"]}
                    </h4>
                    <span class="text-xs text-slate-500 font-mono">
                      v{event["aggregate_version"]}
                    </span>
                  </div>

                  <div class="flex items-center gap-2 text-xs text-slate-400">
                    <.icon name="hero-clock" class="w-3 h-3" />
                    <span>{format_timestamp(event["occurred_at"])}</span>
                  </div>

                  <%= if event["tags"] && length(event["tags"]) > 0 do %>
                    <div class="flex flex-wrap gap-1 mt-2">
                      <%= for tag <- Enum.take(event["tags"], 3) do %>
                        <span class="px-2 py-0.5 rounded text-xs bg-slate-700/50 text-slate-400">
                          {tag}
                        </span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <div class="col-span-5">
          <%= if @selected_event do %>
            <div class="hud-card sticky top-4">
              <div class="flex items-center justify-between mb-4">
                <h3 class="font-bold text-white">Event Details</h3>
                <button
                  phx-click="reconstruct_state"
                  phx-value-version={@selected_event["aggregate_version"]}
                  phx-target={@myself}
                  class="px-3 py-1.5 rounded-lg bg-indigo-500/20 hover:bg-indigo-500/30 text-indigo-300 text-sm transition flex items-center gap-2"
                >
                  <.icon name="hero-arrow-path" class="w-4 h-4" />
                  <span>Reconstruct State</span>
                </button>
              </div>

              <div class="space-y-3 mb-4">
                <div>
                  <p class="text-xs text-slate-500 mb-1">Event Type</p>
                  <p class="text-sm text-white font-medium">{@selected_event["event_type"]}</p>
                </div>

                <div>
                  <p class="text-xs text-slate-500 mb-1">Version</p>
                  <p class="text-sm text-white font-mono">{@selected_event["aggregate_version"]}</p>
                </div>

                <div>
                  <p class="text-xs text-slate-500 mb-1">Occurred At</p>
                  <p class="text-sm text-white">
                    {format_timestamp_full(@selected_event["occurred_at"])}
                  </p>
                </div>

                <%= if @selected_event["correlation_id"] do %>
                  <div>
                    <p class="text-xs text-slate-500 mb-1">Correlation ID</p>
                    <div class="flex items-center gap-2">
                      <p class="text-sm text-white font-mono flex-1 truncate">
                        {@selected_event["correlation_id"]}
                      </p>
                      <button
                        phx-click="trace_correlation"
                        phx-value-correlation_id={@selected_event["correlation_id"]}
                        phx-target={@myself}
                        class="p-1.5 rounded bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition"
                        title="Trace Workflow"
                      >
                        <.icon name="hero-magnifying-glass" class="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                <% end %>
              </div>

              <div class="border-t border-slate-700/50 pt-4">
                <p class="text-xs text-slate-500 mb-2">Event Data</p>
                <pre class="text-xs text-slate-300 bg-slate-900/50 p-3 rounded-lg overflow-auto max-h-64 custom-scrollbar"><%= Jason.encode!(@selected_event["data"], pretty: true) %></pre>
              </div>
            </div>
          <% else %>
            <div class="hud-card flex flex-col items-center justify-center py-12">
              <div class="w-16 h-16 rounded-full bg-slate-700/50 flex items-center justify-center mb-4">
                <.icon name="hero-document-text" class="w-8 h-8 text-slate-500" />
              </div>
              <p class="text-slate-400 text-center">
                Select an event to view details
              </p>
            </div>
          <% end %>
        </div>
      </div>

      <%= if @total_events > @page_size do %>
        <div class="hud-card">
          <div class="flex items-center justify-between">
            <p class="text-sm text-slate-400">
              Showing {(@current_page - 1) * @page_size + 1}-{min(
                @current_page * @page_size,
                @total_events
              )} of {@total_events}
            </p>

            <div class="flex items-center gap-2">
              <%= if @current_page > 1 do %>
                <button
                  phx-click="change_page"
                  phx-value-page={@current_page - 1}
                  phx-target={@myself}
                  class="px-3 py-1.5 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 text-sm transition"
                >
                  Previous
                </button>
              <% end %>

              <span class="px-3 py-1.5 text-sm text-slate-400">
                Page {@current_page} of {ceil(@total_events / @page_size)}
              </span>

              <%= if @current_page * @page_size < @total_events do %>
                <button
                  phx-click="change_page"
                  phx-value-page={@current_page + 1}
                  phx-target={@myself}
                  class="px-3 py-1.5 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 text-sm transition"
                >
                  Next
                </button>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_state_viewer(assigns) do
    ~H"""
    <div class="space-y-4 animate-fade-in">
      <div class="hud-card">
        <div class="flex items-center justify-between mb-4">
          <div class="flex items-center gap-3">
            <button
              phx-click="change_view"
              phx-value-mode="timeline"
              phx-target={@myself}
              class="px-3 py-2 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition flex items-center gap-2"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" />
              <span class="text-sm">Back to Timeline</span>
            </button>

            <div class="h-8 w-px bg-slate-700"></div>

            <h3 class="font-bold text-white">Reconstructed State</h3>
          </div>

          <%= if @reconstructed_state["__metadata__"] do %>
            <div class="flex items-center gap-2">
              <span class="px-3 py-1.5 rounded-lg bg-indigo-500/20 border border-indigo-500/30 text-indigo-300 text-sm">
                Version {@reconstructed_state["__metadata__"]["version"]}
              </span>
              <span class="text-sm text-slate-400">
                {if @reconstructed_state["__metadata__"]["snapshot_used"],
                  do: "From snapshot",
                  else: "Full replay"}
              </span>
            </div>
          <% end %>
        </div>

        <div class="bg-slate-900/50 rounded-lg p-4 border border-slate-700/50">
          <pre class="text-sm text-slate-300 overflow-auto max-h-96 custom-scrollbar"><%= Jason.encode!(
              @reconstructed_state,
              pretty: true
            ) %></pre>
        </div>
      </div>
    </div>
    """
  end

  defp render_diff_viewer(assigns) do
    ~H"""
    <div class="space-y-4 animate-fade-in">
      <div class="hud-card">
        <div class="flex items-center justify-between mb-6">
          <div class="flex items-center gap-3">
            <button
              phx-click="close_diff"
              phx-target={@myself}
              class="px-3 py-2 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition flex items-center gap-2"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
              <span class="text-sm">Close Diff</span>
            </button>

            <div class="h-8 w-px bg-slate-700"></div>

            <h3 class="font-bold text-white">State Comparison</h3>
          </div>

          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2 text-sm">
              <span class="text-slate-400">From:</span>
              <span class="px-2 py-1 rounded bg-red-500/20 text-red-300 font-mono">
                v{@from_version}
              </span>
            </div>
            <.icon name="hero-arrow-right" class="w-4 h-4 text-slate-500" />
            <div class="flex items-center gap-2 text-sm">
              <span class="text-slate-400">To:</span>
              <span class="px-2 py-1 rounded bg-green-500/20 text-green-300 font-mono">
                v{@to_version}
              </span>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-3 gap-4 mb-6">
          <div class="bg-green-500/10 border border-green-500/30 rounded-lg p-4">
            <p class="text-xs text-green-400 mb-2">Added Fields</p>
            <p class="text-2xl font-bold text-green-300">
              {if @state_diff["diff"], do: map_size(@state_diff["diff"]["added"] || %{}), else: 0}
            </p>
          </div>

          <div class="bg-amber-500/10 border border-amber-500/30 rounded-lg p-4">
            <p class="text-xs text-amber-400 mb-2">Modified Fields</p>
            <p class="text-2xl font-bold text-amber-300">
              {if @state_diff["diff"], do: map_size(@state_diff["diff"]["changed"] || %{}), else: 0}
            </p>
          </div>

          <div class="bg-red-500/10 border border-red-500/30 rounded-lg p-4">
            <p class="text-xs text-red-400 mb-2">Removed Fields</p>
            <p class="text-2xl font-bold text-red-300">
              {if @state_diff["diff"], do: map_size(@state_diff["diff"]["removed"] || %{}), else: 0}
            </p>
          </div>
        </div>

        <%= if @state_diff["diff"] do %>
          <div class="space-y-4">
            <%= if map_size(@state_diff["diff"]["added"] || %{}) > 0 do %>
              <div class="bg-slate-900/50 rounded-lg p-4 border border-green-500/30">
                <h4 class="font-semibold text-green-400 mb-3 flex items-center gap-2">
                  <.icon name="hero-plus-circle" class="w-5 h-5" />
                  <span>Added Fields</span>
                </h4>
                <div class="space-y-2">
                  <%= for {key, value} <- @state_diff["diff"]["added"] do %>
                    <div class="bg-green-500/5 rounded p-3 border-l-2 border-green-500">
                      <p class="text-sm font-mono text-green-300 mb-1">{key}</p>
                      <pre class="text-xs text-slate-300"><%= inspect(value, pretty: true) %></pre>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= if map_size(@state_diff["diff"]["changed"] || %{}) > 0 do %>
              <div class="bg-slate-900/50 rounded-lg p-4 border border-amber-500/30">
                <h4 class="font-semibold text-amber-400 mb-3 flex items-center gap-2">
                  <.icon name="hero-arrow-path" class="w-5 h-5" />
                  <span>Modified Fields</span>
                </h4>
                <div class="space-y-3">
                  <%= for {key, changes} <- @state_diff["diff"]["changed"] do %>
                    <div class="bg-amber-500/5 rounded p-3 border-l-2 border-amber-500">
                      <p class="text-sm font-mono text-amber-300 mb-2">{key}</p>
                      <div class="grid grid-cols-2 gap-3">
                        <div>
                          <p class="text-xs text-red-400 mb-1">Before</p>
                          <pre class="text-xs text-slate-300 bg-red-500/10 p-2 rounded"><%= inspect(
                              changes["from"],
                              pretty: true
                            ) %></pre>
                        </div>
                        <div>
                          <p class="text-xs text-green-400 mb-1">After</p>
                          <pre class="text-xs text-slate-300 bg-green-500/10 p-2 rounded"><%= inspect(
                              changes["to"],
                              pretty: true
                            ) %></pre>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= if map_size(@state_diff["diff"]["removed"] || %{}) > 0 do %>
              <div class="bg-slate-900/50 rounded-lg p-4 border border-red-500/30">
                <h4 class="font-semibold text-red-400 mb-3 flex items-center gap-2">
                  <.icon name="hero-minus-circle" class="w-5 h-5" />
                  <span>Removed Fields</span>
                </h4>
                <div class="space-y-2">
                  <%= for {key, value} <- @state_diff["diff"]["removed"] do %>
                    <div class="bg-red-500/5 rounded p-3 border-l-2 border-red-500">
                      <p class="text-sm font-mono text-red-300 mb-1">{key}</p>
                      <pre class="text-xs text-slate-300"><%= inspect(value, pretty: true) %></pre>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_search_results(assigns) do
    ~H"""
    <div class="space-y-4 animate-fade-in">
      <div class="hud-card">
        <div class="flex items-center gap-3 mb-4">
          <button
            phx-click="clear_search"
            phx-target={@myself}
            class="px-3 py-2 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition flex items-center gap-2"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
            <span class="text-sm">Clear Search</span>
          </button>

          <div class="h-8 w-px bg-slate-700"></div>

          <h3 class="font-bold text-white">
            Search Results
            <span class="text-slate-500 font-normal ml-2">
              ({length(@search_results)} events found)
            </span>
          </h3>
        </div>

        <div class="space-y-2 max-h-[600px] overflow-y-auto custom-scrollbar">
          <%= for event <- @search_results do %>
            <div class="bg-slate-900/50 rounded-lg p-4 border border-slate-700/50 hover:border-slate-600 transition">
              <div class="flex items-start justify-between mb-3">
                <div>
                  <h4 class="font-medium text-white">{event["event_type"]}</h4>
                  <p class="text-xs text-slate-500 font-mono mt-1">
                    {event["aggregate_id"]}
                  </p>
                </div>
                <span class="px-2 py-1 rounded text-xs bg-indigo-500/20 text-indigo-300 font-mono">
                  v{event["aggregate_version"]}
                </span>
              </div>

              <p class="text-sm text-slate-300 mb-2">
                {format_timestamp(event["occurred_at"])}
              </p>

              <pre class="text-xs text-slate-400 bg-slate-900 p-2 rounded overflow-auto"><%= Jason.encode!(
                  event["data"],
                  pretty: true
                ) %></pre>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp render_correlation_trace(assigns) do
    ~H"""
    <div class="space-y-4 animate-fade-in">
      <div class="hud-card">
        <div class="flex items-center gap-3 mb-6">
          <button
            phx-click="change_view"
            phx-value-mode="timeline"
            phx-target={@myself}
            class="px-3 py-2 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition flex items-center gap-2"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
            <span class="text-sm">Back</span>
          </button>

          <div class="h-8 w-px bg-slate-700"></div>

          <h3 class="font-bold text-white">Distributed Workflow Trace</h3>
        </div>

        <%= if @correlation_trace do %>
          <div class="grid grid-cols-3 gap-4 mb-6">
            <div class="bg-indigo-500/10 border border-indigo-500/30 rounded-lg p-4">
              <p class="text-xs text-indigo-400 mb-2">Total Events</p>
              <p class="text-2xl font-bold text-indigo-300">
                {@correlation_trace["total_events"]}
              </p>
            </div>

            <div class="bg-purple-500/10 border border-purple-500/30 rounded-lg p-4">
              <p class="text-xs text-purple-400 mb-2">Affected Aggregates</p>
              <p class="text-2xl font-bold text-purple-300">
                {@correlation_trace["affected_aggregates"]}
              </p>
            </div>

            <div class="bg-cyan-500/10 border border-cyan-500/30 rounded-lg p-4">
              <p class="text-xs text-cyan-400 mb-2">Correlation ID</p>
              <p class="text-xs font-mono text-cyan-300 truncate">
                {@correlation_trace["correlation_id"]}
              </p>
            </div>
          </div>

          <div class="space-y-4">
            <%= for workflow <- @correlation_trace["workflow"] || [] do %>
              <div class="bg-slate-900/50 rounded-lg p-4 border border-slate-700/50">
                <div class="flex items-center justify-between mb-3">
                  <div>
                    <h4 class="font-semibold text-white">{workflow["aggregate_type"]}</h4>
                    <p class="text-xs text-slate-500 font-mono">{workflow["aggregate_id"]}</p>
                  </div>
                  <span class="px-2 py-1 rounded text-xs bg-slate-700 text-slate-300">
                    {workflow["event_count"]} events
                  </span>
                </div>

                <div class="space-y-2">
                  <%= for event <- workflow["events"] do %>
                    <div class="bg-slate-800/50 rounded p-3 border border-slate-700/30">
                      <div class="flex items-center justify-between mb-2">
                        <span class="text-sm font-medium text-slate-300">{event["event_type"]}</span>
                        <span class="text-xs text-slate-500">
                          {format_timestamp(event["occurred_at"])}
                        </span>
                      </div>
                      <pre class="text-xs text-slate-400 max-h-24 overflow-auto"><%= Jason.encode!(
                          event["data"],
                          pretty: true
                        ) %></pre>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_timestamp(nil), do: "N/A"

  defp format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} -> format_relative_time(dt)
      _ -> timestamp
    end
  end

  defp format_timestamp(%DateTime{} = dt), do: format_relative_time(dt)
  defp format_timestamp(_), do: "N/A"

  defp format_timestamp_full(nil), do: "N/A"

  defp format_timestamp_full(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> timestamp
    end
  end

  defp format_timestamp_full(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_timestamp_full(_), do: "N/A"

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
end
