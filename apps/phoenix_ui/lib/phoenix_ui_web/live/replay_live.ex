defmodule PhoenixUiWeb.ReplayLive do
  use PhoenixUiWeb, :live_view
  require Logger
  alias Orchestrator.{Repo, Event}
  alias PhoenixUiWeb.ReplayComponents
  @default_page_size 100
  @playback_speeds [0.25, 0.5, 1.0, 2.0, 4.0, 10.0]
  @timeline_chunk_size 1000
  @impl true
  def mount(%{"aggregate_id" => aggregate_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Orchestrator.PubSub, "events:#{aggregate_id}")
    end

    {:ok, aggregate_info} = load_aggregate_info(aggregate_id)
    {:ok, events} = load_initial_events(aggregate_id)
    {:ok, timeline_chunks} = build_timeline_chunks(aggregate_id)

    socket =
      socket
      |> assign(:aggregate_id, aggregate_id)
      |> assign(:aggregate_info, aggregate_info)
      |> assign(:events, events)
      |> assign(:timeline_chunks, timeline_chunks)
      |> assign(:current_position, length(events))
      |> assign(:playback_state, :paused)
      |> assign(:playback_speed, 1.0)
      |> assign(:playback_timer, nil)
      |> assign(:selected_event, nil)
      |> assign(:current_state, nil)
      |> assign(:comparison_state, nil)
      |> assign(:view_mode, :timeline)
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:filters, %{event_type: nil, actor: nil, date_range: nil})
      |> assign(:zoom_level, 1.0)
      |> assign(:page, 1)
      |> assign(:loading, false)

    {:ok, socket, temporary_assigns: [events: []]}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, aggregates} = list_all_aggregates()

    socket =
      socket
      |> assign(:aggregates, aggregates)
      |> assign(:view_mode, :aggregate_list)

    {:ok, socket}
  end

  @impl true
  def handle_event("play", _params, socket) do
    socket = start_playback(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("pause", _params, socket) do
    socket = pause_playback(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("step_forward", _params, socket) do
    socket = step_forward(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("step_backward", _params, socket) do
    socket = step_backward(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("jump_to", %{"position" => position}, socket) do
    position = String.to_integer(position)
    socket = jump_to_position(socket, position)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_speed", %{"speed" => speed}, socket) do
    speed = String.to_float(speed)
    socket = assign(socket, :playback_speed, speed)

    if socket.assigns.playback_state == :playing do
      socket = socket |> pause_playback() |> start_playback()
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_event", %{"event_id" => event_id}, socket) do
    event = Enum.find(socket.assigns.events, &(&1.id == event_id))

    socket =
      socket
      |> assign(:selected_event, event)
      |> assign(:view_mode, :event_detail)

    {:noreply, socket}
  end

  @impl true
  def handle_event("zoom_in", _params, socket) do
    new_zoom = min(socket.assigns.zoom_level * 1.5, 10.0)
    socket = assign(socket, :zoom_level, new_zoom)
    {:noreply, socket}
  end

  @impl true
  def handle_event("zoom_out", _params, socket) do
    new_zoom = max(socket.assigns.zoom_level / 1.5, 0.1)
    socket = assign(socket, :zoom_level, new_zoom)
    {:noreply, socket}
  end

  @impl true
  def handle_event("zoom_reset", _params, socket) do
    socket = assign(socket, :zoom_level, 1.0)
    {:noreply, socket}
  end

  @impl true
  def handle_event("show_state", %{"position" => position}, socket) do
    position = String.to_integer(position)
    {:ok, state} = rebuild_state_at_position(socket.assigns.aggregate_id, position)

    socket =
      socket
      |> assign(:current_state, state)
      |> assign(:view_mode, :state)

    {:noreply, socket}
  end

  @impl true
  def handle_event("compare_states", %{"from" => from_pos, "to" => to_pos}, socket) do
    from_pos = String.to_integer(from_pos)
    to_pos = String.to_integer(to_pos)
    {:ok, from_state} = rebuild_state_at_position(socket.assigns.aggregate_id, from_pos)
    {:ok, to_state} = rebuild_state_at_position(socket.assigns.aggregate_id, to_pos)
    diff = compute_state_diff(from_state, to_state)

    socket =
      socket
      |> assign(:current_state, from_state)
      |> assign(:comparison_state, to_state)
      |> assign(:state_diff, diff)
      |> assign(:view_mode, :diff)

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket = assign(socket, :loading, true)
    send(self(), {:perform_search, query})
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    socket =
      socket
      |> assign(:filters, parse_filters(filters))
      |> assign(:loading, true)

    send(self(), :reload_events)
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:filters, %{event_type: nil, actor: nil, date_range: nil})
      |> assign(:loading, true)

    send(self(), :reload_events)
    {:noreply, socket}
  end

  @impl true
  def handle_event("trace_correlation", %{"correlation_id" => correlation_id}, socket) do
    {:ok, correlated_events} = trace_correlation(correlation_id)

    socket =
      socket
      |> assign(:correlated_events, correlated_events)
      |> assign(:view_mode, :correlation)

    {:noreply, socket}
  end

  @impl true
  def handle_event("export", %{"format" => format}, socket) do
    aggregate_id = socket.assigns.aggregate_id
    events = socket.assigns.events

    case format do
      "json" ->
        download_json(socket, aggregate_id, events)

      "csv" ->
        download_csv(socket, aggregate_id, events)

      "timeline" ->
        generate_timeline_image(socket, aggregate_id, events)
    end
  end

  @impl true
  def handle_info({:perform_search, query}, socket) do
    aggregate_id = socket.assigns.aggregate_id
    {:ok, results} = search_events(aggregate_id, query)

    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:search_results, results)
      |> assign(:view_mode, :search)
      |> assign(:loading, false)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:reload_events, socket) do
    aggregate_id = socket.assigns.aggregate_id
    filters = socket.assigns.filters
    {:ok, events} = load_filtered_events(aggregate_id, filters)

    socket =
      socket
      |> assign(:events, events)
      |> assign(:current_position, length(events))
      |> assign(:loading, false)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:playback_tick, socket) do
    if socket.assigns.playback_state == :playing do
      socket = step_forward(socket)

      if socket.assigns.current_position < length(socket.assigns.events) do
        schedule_playback_tick(socket.assigns.playback_speed)
        {:noreply, socket}
      else
        socket = pause_playback(socket)
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:new_event, event}, socket) do
    events = socket.assigns.events ++ [event]

    socket =
      socket
      |> assign(:events, events)
      |> update(:timeline_chunks, &append_to_chunks(&1, event))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="replay-container h-screen flex flex-col bg-gray-50">
      <%= if @view_mode == :aggregate_list do %>
        {render_aggregate_list(assigns)}
      <% else %>
        <!-- Header -->
        <div class="replay-header bg-white shadow-sm p-4 flex items-center justify-between">
          <div class="flex items-center space-x-4">
            <h1 class="text-2xl font-bold text-gray-800">Event Replay</h1>
            <div class="text-sm text-gray-600">
              <span class="font-medium">{@aggregate_info.type}</span>
              <span class="mx-2">•</span>
              <span>{@aggregate_info.id}</span>
            </div>
          </div>
          <div class="flex items-center space-x-2">
            {render_export_buttons(assigns)}
          </div>
        </div>
        <!-- Playback Controls -->
        <div class="playback-controls bg-white border-b border-gray-200 p-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center space-x-2">
              <%= if @playback_state == :paused do %>
                <button phx-click="play" class="btn btn-primary">
                  <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
                    <path d="M6.3 2.841A1.5 1.5 0 004 4.11V15.89a1.5 1.5 0 002.3 1.269l9.344-5.89a1.5 1.5 0 000-2.538L6.3 2.84z" />
                  </svg>
                </button>
              <% else %>
                <button phx-click="pause" class="btn btn-primary">
                  <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
                    <path d="M5.75 3a.75.75 0 00-.75.75v12.5c0 .414.336.75.75.75h1.5a.75.75 0 00.75-.75V3.75A.75.75 0 007.25 3h-1.5zM12.75 3a.75.75 0 00-.75.75v12.5c0 .414.336.75.75.75h1.5a.75.75 0 00.75-.75V3.75a.75.75 0 00-.75-.75h-1.5z" />
                  </svg>
                </button>
              <% end %>
              <button phx-click="step_backward" class="btn">
                <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
                  <path d="M7.712 4.819A1.5 1.5 0 0110 6.095v2.973c.104-.131.234-.248.389-.344l6.323-3.905A1.5 1.5 0 0119 6.095v7.81a1.5 1.5 0 01-2.288 1.276l-6.323-3.905a1.505 1.505 0 01-.389-.344v2.973a1.5 1.5 0 01-2.288 1.276l-6.323-3.905a1.5 1.5 0 010-2.552l6.323-3.905z" />
                </svg>
              </button>
              <button phx-click="step_forward" class="btn">
                <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
                  <path d="M12.288 4.819A1.5 1.5 0 0010 6.095v2.973c-.104-.131-.234-.248-.389-.344l-6.323-3.905A1.5 1.5 0 001 6.095v7.81a1.5 1.5 0 002.288 1.276l6.323-3.905c.155-.096.285-.213.389-.344v2.973a1.5 1.5 0 002.288 1.276l6.323-3.905a1.5 1.5 0 000-2.552l-6.323-3.905z" />
                </svg>
              </button>
            </div>
            <div class="flex items-center space-x-4">
              <div class="flex items-center space-x-2">
                <span class="text-sm text-gray-600">Speed:</span>
                <select phx-change="set_speed" name="speed" class="form-select text-sm">
                  <%= for speed <- @playback_speeds do %>
                    <option value={speed} selected={speed == @playback_speed}>
                      {speed}x
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="flex items-center space-x-2">
                <span class="text-sm text-gray-600">Position:</span>
                <span class="font-mono text-sm font-medium">
                  {@current_position} / {length(@events)}
                </span>
              </div>
            </div>
          </div>
          <!-- Timeline Scrubber -->
          <div class="mt-4">
            <input
              type="range"
              min="0"
              max={length(@events)}
              value={@current_position}
              phx-change="jump_to"
              name="position"
              class="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer"
            />
          </div>
        </div>
        <!-- Main Content Area -->
        <div class="flex-1 flex overflow-hidden">
          <!-- Timeline Sidebar -->
          <div class="timeline-sidebar w-64 bg-white border-r border-gray-200 overflow-y-auto">
            {render_timeline_sidebar(assigns)}
          </div>
          <!-- Content Panel -->
          <div class="flex-1 overflow-y-auto p-6">
            <%= case @view_mode do %>
              <% :timeline -> %>
                {render_timeline_view(assigns)}
              <% :state -> %>
                {render_state_view(assigns)}
              <% :diff -> %>
                {render_diff_view(assigns)}
              <% :search -> %>
                {render_search_view(assigns)}
              <% :correlation -> %>
                {render_correlation_view(assigns)}
              <% :event_detail -> %>
                {render_event_detail(assigns)}
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_aggregate_list(assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-3xl font-bold mb-6">Event Aggregates</h1>
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <%= for aggregate <- @aggregates do %>
          <a
            href={"/replay/#{aggregate.id}"}
            class="block p-6 bg-white rounded-lg shadow hover:shadow-lg transition"
          >
            <div class="flex items-center justify-between mb-2">
              <h3 class="text-lg font-semibold">{aggregate.type}</h3>
              <span class="text-sm text-gray-500">{aggregate.event_count} events</span>
            </div>
            <p class="text-sm text-gray-600 mb-2">{aggregate.id}</p>
            <p class="text-xs text-gray-400">
              Last event: {format_timestamp(aggregate.last_event_at)}
            </p>
          </a>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_export_buttons(assigns) do
    ~H"""
    <div class="flex space-x-2">
      <button phx-click="export" phx-value-format="json" class="btn btn-sm">
        Export JSON
      </button>
      <button phx-click="export" phx-value-format="csv" class="btn btn-sm">
        Export CSV
      </button>
      <button phx-click="export" phx-value-format="timeline" class="btn btn-sm">
        Export Timeline
      </button>
    </div>
    """
  end

  defp render_timeline_sidebar(assigns) do
    ~H"""
    <div class="p-4">
      <h3 class="text-sm font-semibold text-gray-700 mb-3">Navigation</h3>
      <nav class="space-y-1">
        <button
          phx-click="switch_view"
          phx-value-view="timeline"
          class={"nav-item " <> if @view_mode == :timeline, do: "active", else: ""}
        >
          Timeline
        </button>
        <button
          phx-click="switch_view"
          phx-value-view="search"
          class={"nav-item " <> if @view_mode == :search, do: "active", else: ""}
        >
          Search
        </button>
      </nav>
      <h3 class="text-sm font-semibold text-gray-700 mt-6 mb-3">Snapshots</h3>
      <div class="space-y-2">
        <%= for snapshot <- get_snapshots(@aggregate_id) do %>
          <button
            phx-click="jump_to"
            phx-value-position={snapshot.version}
            class="w-full text-left px-3 py-2 text-sm rounded hover:bg-gray-100"
          >
            <div class="font-medium">Version {snapshot.version}</div>
            <div class="text-xs text-gray-500">
              {format_timestamp(snapshot.created_at)}
            </div>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_timeline_view(assigns) do
    ~H"""
    <div class="timeline-view">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-xl font-semibold">Event Timeline</h2>
        <div class="flex space-x-2">
          <button phx-click="zoom_in" class="btn btn-sm">Zoom In</button>
          <button phx-click="zoom_out" class="btn btn-sm">Zoom Out</button>
          <button phx-click="zoom_reset" class="btn btn-sm">Reset</button>
        </div>
      </div>
      <div class="timeline-canvas bg-white rounded-lg shadow p-6" phx-hook="Timeline">
        <svg id="timeline-svg" class="w-full" style={"height: #{400 * @zoom_level}px"}>
          <!-- Timeline rendering via JavaScript hook -->
        </svg>
      </div>
      <div class="event-list mt-6">
        <h3 class="text-lg font-semibold mb-3">Events</h3>
        <div class="space-y-2">
          <%= for {event, index} <- Enum.with_index(@events) do %>
            <div
              class={"event-card p-4 rounded " <> if index == @current_position - 1, do: "bg-blue-50 border-blue-300", else: "bg-white border-gray-200"}
              phx-click="select_event"
              phx-value-event_id={event.id}
            >
              <div class="flex items-center justify-between">
                <div class="flex items-center space-x-3">
                  <span class="text-xs font-mono text-gray-500">#{index + 1}</span>
                  <span class="font-medium">{event.event_type}</span>
                </div>
                <span class="text-sm text-gray-500">
                  {format_timestamp(event.occurred_at)}
                </span>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp render_state_view(assigns) do
    ~H"""
    <div class="state-view">
      <h2 class="text-xl font-semibold mb-4">State at Position {@current_position}</h2>
      <div class="bg-white rounded-lg shadow p-6">
        <pre class="language-json"><code><%= Jason.encode!(@current_state, pretty: true) %></code></pre>
      </div>
    </div>
    """
  end

  defp render_diff_view(assigns) do
    ~H"""
    <div class="diff-view">
      <h2 class="text-xl font-semibold mb-4">State Diff</h2>
      <div class="grid grid-cols-2 gap-4">
        <div>
          <h3 class="text-lg font-medium mb-2">Before</h3>
          <div class="bg-white rounded-lg shadow p-6">
            <pre class="language-json"><code><%= Jason.encode!(@current_state, pretty: true) %></code></pre>
          </div>
        </div>
        <div>
          <h3 class="text-lg font-medium mb-2">After</h3>
          <div class="bg-white rounded-lg shadow p-6">
            <pre class="language-json"><code><%= Jason.encode!(@comparison_state, pretty: true) %></code></pre>
          </div>
        </div>
      </div>
      <div class="mt-6">
        <h3 class="text-lg font-medium mb-2">Changes</h3>
        <div class="bg-white rounded-lg shadow p-6">
          {render_diff_hunks(@state_diff)}
        </div>
      </div>
    </div>
    """
  end

  defp render_search_view(assigns) do
    ~H"""
    <div class="search-view">
      <h2 class="text-xl font-semibold mb-4">Search Events</h2>
      <form phx-submit="search" class="mb-6">
        <input
          type="text"
          name="query"
          value={@search_query}
          placeholder="Search event payloads..."
          class="w-full form-input"
        />
      </form>
      <%= if @loading do %>
        <div class="flex justify-center p-8">
          <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-500"></div>
        </div>
      <% else %>
        <div class="space-y-2">
          <%= for result <- @search_results do %>
            <div class="bg-white rounded-lg shadow p-4">
              <div class="flex items-center justify-between mb-2">
                <span class="font-medium">{result.event_type}</span>
                <span class="text-sm text-gray-500">
                  {format_timestamp(result.occurred_at)}
                </span>
              </div>
              <div class="text-sm text-gray-600">
                {highlight_matches(result.data, @search_query)}
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_correlation_view(assigns) do
    ~H"""
    <div class="correlation-view">
      <h2 class="text-xl font-semibold mb-4">Correlation Trace</h2>
      <div class="space-y-4">
        <%= for event <- @correlated_events do %>
          <div class="bg-white rounded-lg shadow p-4">
            <div class="flex items-center justify-between mb-2">
              <div>
                <span class="font-medium">{event.event_type}</span>
                <span class="mx-2 text-gray-400">•</span>
                <span class="text-sm text-gray-600">{event.aggregate_id}</span>
              </div>
              <span class="text-sm text-gray-500">
                {format_timestamp(event.occurred_at)}
              </span>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_event_detail(assigns) do
    ~H"""
    <div class="event-detail">
      <h2 class="text-xl font-semibold mb-4">Event Details</h2>
      <%= if @selected_event do %>
        <div class="bg-white rounded-lg shadow p-6">
          <dl class="grid grid-cols-2 gap-4">
            <div>
              <dt class="text-sm font-medium text-gray-500">Event Type</dt>
              <dd class="mt-1 text-sm text-gray-900">{@selected_event.event_type}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-gray-500">Aggregate Version</dt>
              <dd class="mt-1 text-sm text-gray-900">{@selected_event.aggregate_version}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-gray-500">Occurred At</dt>
              <dd class="mt-1 text-sm text-gray-900">
                {format_timestamp(@selected_event.occurred_at)}
              </dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-gray-500">Actor</dt>
              <dd class="mt-1 text-sm text-gray-900">{@selected_event.actor}</dd>
            </div>
          </dl>
          <div class="mt-6">
            <h3 class="text-sm font-medium text-gray-500 mb-2">Event Data</h3>
            <pre class="language-json bg-gray-50 rounded p-4"><code><%= Jason.encode!(@selected_event.data, pretty: true) %></code></pre>
          </div>
          <%= if @selected_event.metadata do %>
            <div class="mt-6">
              <h3 class="text-sm font-medium text-gray-500 mb-2">Metadata</h3>
              <pre class="language-json bg-gray-50 rounded p-4"><code><%= Jason.encode!(@selected_event.metadata, pretty: true) %></code></pre>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp load_aggregate_info(aggregate_id) do
    {:ok,
     %{
       id: aggregate_id,
       type: "Machine",
       event_count: 0,
       last_event_at: DateTime.utc_now()
     }}
  end

  defp load_initial_events(aggregate_id) do
    events =
      Repo.all(
        from(e in "events",
          where: e.aggregate_id == ^aggregate_id,
          order_by: [asc: e.aggregate_version],
          limit: @default_page_size
        )
      )

    {:ok, events}
  end

  defp build_timeline_chunks(aggregate_id) do
    {:ok, []}
  end

  defp list_all_aggregates do
    {:ok, []}
  end

  defp rebuild_state_at_position(aggregate_id, position) do
    {:ok, %{}}
  end

  defp compute_state_diff(from_state, to_state) do
    []
  end

  defp search_events(aggregate_id, query) do
    {:ok, []}
  end

  defp trace_correlation(correlation_id) do
    {:ok, []}
  end

  defp load_filtered_events(aggregate_id, filters) do
    {:ok, []}
  end

  defp parse_filters(filters) do
    %{}
  end

  defp start_playback(socket) do
    socket = assign(socket, :playback_state, :playing)
    schedule_playback_tick(socket.assigns.playback_speed)
    socket
  end

  defp pause_playback(socket) do
    assign(socket, :playback_state, :paused)
  end

  defp step_forward(socket) do
    new_position = min(socket.assigns.current_position + 1, length(socket.assigns.events))
    assign(socket, :current_position, new_position)
  end

  defp step_backward(socket) do
    new_position = max(socket.assigns.current_position - 1, 0)
    assign(socket, :current_position, new_position)
  end

  defp jump_to_position(socket, position) do
    position = max(0, min(position, length(socket.assigns.events)))
    assign(socket, :current_position, position)
  end

  defp schedule_playback_tick(speed) do
    delay = trunc(1000 / speed)
    Process.send_after(self(), :playback_tick, delay)
  end

  defp append_to_chunks(chunks, event) do
    chunks ++ [event]
  end

  defp get_snapshots(aggregate_id) do
    []
  end

  defp format_timestamp(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  defp render_diff_hunks(diff) do
    ""
  end

  defp highlight_matches(data, query) do
    Jason.encode!(data)
  end

  defp download_json(socket, aggregate_id, events) do
    socket
  end

  defp download_csv(socket, aggregate_id, events) do
    socket
  end

  defp generate_timeline_image(socket, aggregate_id, events) do
    socket
  end
end
