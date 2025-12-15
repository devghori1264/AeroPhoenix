defmodule PhoenixUiWeb.NetworkCaptureLive do
  use PhoenixUiWeb, :live_view
  require Logger

  alias Orchestrator.Debugger.NetworkCapture

  @max_packets_default 10_000
  @max_size_mb_default 100
  @max_duration_sec_default 300

  @impl true
  def mount(%{"machine_id" => machine_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PhoenixUi.PubSub, "network_capture:#{machine_id}")
    end

    initial_state = %{
      machine_id: machine_id,
      capture_pid: nil,
      capturing: false,
      paused: false,
      packets: [],
      flows: %{},
      stats: %{
        packets_captured: 0,
        packets_dropped: 0,
        bytes_captured: 0,
        capture_rate: 0,
        bandwidth_mbps: 0
      },
      filter: "",
      selected_packet: nil,
      display_filter: %{protocol: nil, source_ip: nil, dest_ip: nil},
      options: %{
        max_packets: @max_packets_default,
        max_size_mb: @max_size_mb_default,
        max_duration_sec: @max_duration_sec_default,
        full_payload: false,
        protocols: [:tcp, :udp]
      },
      start_time: nil,
      error: nil
    }

    socket =
      socket
      |> assign(initial_state)
      |> assign(:page_title, "Network Capture: #{machine_id}")

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns.capture_pid do
      NetworkCapture.stop(socket.assigns.capture_pid)
    end

    :ok
  end

  @impl true
  def handle_event("start_capture", params, socket) do
    filter = Map.get(params, "filter", "")
    full_payload = Map.get(params, "full_payload", false)

    options = [
      filter: if(filter != "", do: filter, else: nil),
      max_packets: socket.assigns.options.max_packets,
      max_size_mb: socket.assigns.options.max_size_mb,
      full_payload: full_payload,
      protocols: socket.assigns.options.protocols
    ]

    case NetworkCapture.start(socket.assigns.machine_id, options) do
      {:ok, capture_pid} ->
        Logger.info("Network capture started",
          machine_id: socket.assigns.machine_id,
          filter: filter,
          pid: inspect(capture_pid)
        )

        Task.start(fn ->
          stream_packets(capture_pid, socket.assigns.machine_id)
        end)

        Process.send_after(
          self(),
          :auto_stop_capture,
          socket.assigns.options.max_duration_sec * 1000
        )

        Process.send_after(self(), :update_stats, 1000)

        socket =
          socket
          |> assign(:capture_pid, capture_pid)
          |> assign(:capturing, true)
          |> assign(:start_time, DateTime.utc_now())
          |> assign(:filter, filter)
          |> assign(:error, nil)
          |> assign(:packets, [])
          |> assign(:flows, %{})

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to start network capture",
          machine_id: socket.assigns.machine_id,
          reason: inspect(reason)
        )

        socket =
          socket
          |> assign(:error, "Failed to start capture: #{inspect(reason)}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop_capture", _params, socket) do
    if socket.assigns.capture_pid do
      case NetworkCapture.stop(socket.assigns.capture_pid) do
        {:ok, result} ->
          Logger.info("Network capture stopped",
            machine_id: socket.assigns.machine_id,
            packets_captured: result.stats.packets_captured
          )

          socket =
            socket
            |> assign(:capturing, false)
            |> assign(:capture_pid, nil)
            |> assign(:flows, map_flows(result.flows))
            |> assign(:stats, result.stats)

          {:noreply, socket}

        {:error, reason} ->
          Logger.error("Failed to stop capture", reason: inspect(reason))
          {:noreply, assign(socket, :error, "Failed to stop: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("pause_capture", _params, socket) do
    socket = assign(socket, :paused, true)
    {:noreply, socket}
  end

  @impl true
  def handle_event("resume_capture", _params, socket) do
    socket = assign(socket, :paused, false)
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_packets", _params, socket) do
    socket =
      socket
      |> assign(:packets, [])
      |> assign(:selected_packet, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("export_pcap", _params, socket) do
    if socket.assigns.capture_pid do
      path = "/tmp/capture_#{socket.assigns.machine_id}_#{:os.system_time(:second)}.pcap"

      case NetworkCapture.export_pcap(socket.assigns.capture_pid, path) do
        :ok ->
          Logger.info("Exported PCAP", machine_id: socket.assigns.machine_id, path: path)

          socket = push_event(socket, "download_pcap", %{path: path})
          {:noreply, socket}

        {:error, reason} ->
          Logger.error("Failed to export PCAP", reason: inspect(reason))
          {:noreply, assign(socket, :error, "Export failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_packet", %{"packet_id" => packet_id}, socket) do
    packet =
      Enum.find(socket.assigns.packets, fn p ->
        to_string(p.id) == packet_id
      end)

    socket = assign(socket, :selected_packet, packet)
    {:noreply, socket}
  end

  @impl true
  def handle_event("apply_display_filter", params, socket) do
    display_filter = %{
      protocol: Map.get(params, "protocol"),
      source_ip: Map.get(params, "source_ip"),
      dest_ip: Map.get(params, "dest_ip")
    }

    socket = assign(socket, :display_filter, display_filter)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:packet, packet}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      packet_with_id = Map.put(packet, :id, :erlang.unique_integer([:positive]))

      new_packets = [packet_with_id | socket.assigns.packets]
      limited_packets = Enum.take(new_packets, socket.assigns.options.max_packets)

      new_stats = %{
        socket.assigns.stats
        | packets_captured: socket.assigns.stats.packets_captured + 1,
          bytes_captured: socket.assigns.stats.bytes_captured + packet.length
      }

      socket =
        socket
        |> assign(:packets, limited_packets)
        |> assign(:stats, new_stats)
        |> push_event("packet", %{packet: serialize_packet(packet_with_id)})

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:capture_stopped, reason}, socket) do
    Logger.info("Capture stopped", machine_id: socket.assigns.machine_id, reason: reason)

    socket =
      socket
      |> assign(:capturing, false)
      |> assign(:capture_pid, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:auto_stop_capture, socket) do
    if socket.assigns.capturing do
      Logger.warning("Auto-stopping capture (max duration reached)",
        machine_id: socket.assigns.machine_id
      )

      handle_event("stop_capture", %{}, socket)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:update_stats, socket) do
    if socket.assigns.capturing && socket.assigns.capture_pid do
      case NetworkCapture.get_stats(socket.assigns.capture_pid) do
        {:ok, stats} ->
          duration_sec = stats[:duration_seconds] || 1
          capture_rate = stats[:packets_captured] / max(duration_sec, 1)
          bandwidth_mbps = stats[:bytes_captured] * 8 / max(duration_sec, 1) / 1_000_000

          new_stats = %{
            packets_captured: stats[:packets_captured] || 0,
            packets_dropped: stats[:packets_dropped] || 0,
            bytes_captured: stats[:bytes_captured] || 0,
            capture_rate: Float.round(capture_rate, 1),
            bandwidth_mbps: Float.round(bandwidth_mbps, 2)
          }

          socket = assign(socket, :stats, new_stats)

          Process.send_after(self(), :update_stats, 1000)

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="network-capture-container" phx-hook="NetworkCapture" id="network-capture">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-3xl font-bold text-gray-900 dark:text-gray-100">
            Network Capture
          </h1>
          <p class="text-gray-600 dark:text-gray-400 mt-1">
            Machine: <code class="px-2 py-1 bg-gray-100 dark:bg-gray-800 rounded">{@machine_id}</code>
          </p>
        </div>
        <div class="flex items-center gap-3">
          <%= if @capturing do %>
            <span class="flex items-center gap-2 px-3 py-2 bg-green-100 dark:bg-green-900 text-green-800 dark:text-green-200 rounded-lg">
              <span class="animate-pulse h-3 w-3 bg-green-500 rounded-full"></span> Capturing
            </span>
            <%= if @paused do %>
              <button
                phx-click="resume_capture"
                class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition"
              >
                Resume
              </button>
            <% else %>
              <button
                phx-click="pause_capture"
                class="px-4 py-2 bg-yellow-600 hover:bg-yellow-700 text-white rounded-lg transition"
              >
                Pause
              </button>
            <% end %>
            <button
              phx-click="stop_capture"
              class="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-lg transition"
            >
              Stop
            </button>
          <% else %>
            <button
              phx-click="start_capture"
              phx-value-filter={@filter}
              class="px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg transition"
            >
              Start Capture
            </button>
          <% end %>
        </div>
      </div>

      <%= if @error do %>
        <div class="mb-4 p-4 bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200 rounded-lg">
          <strong>Error:</strong> {@error}
        </div>
      <% end %>

      <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-4 mb-4">
        <div class="flex items-center gap-4">
          <div class="flex-1">
            <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              BPF Filter (tcpdump syntax)
            </label>
            <input
              type="text"
              phx-value-filter={@filter}
              placeholder="tcp port 443, src host 10.0.1.5, icmp"
              class="w-full px-4 py-2 bg-gray-50 dark:bg-gray-900 border border-gray-300 dark:border-gray-700 rounded-lg focus:ring-2 focus:ring-blue-500"
              disabled={@capturing}
            />
            <p class="text-xs text-gray-500 dark:text-gray-400 mt-1">
              Examples: <code>tcp port 5432</code>, <code>src host 192.168.1.1</code>,
              <code>icmp</code>
            </p>
          </div>
          <div class="flex items-center gap-2">
            <label class="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300">
              <input type="checkbox" class="rounded" disabled={@capturing} /> Full payload
            </label>
          </div>
        </div>
      </div>

      <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-4 mb-4">
        <div class="grid grid-cols-5 gap-4">
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Packets</div>
            <div class="text-2xl font-bold text-gray-900 dark:text-gray-100">
              {@stats.packets_captured}
            </div>
          </div>
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Dropped</div>
            <div class="text-2xl font-bold text-red-600 dark:text-red-400">
              {@stats.packets_dropped}
            </div>
          </div>
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Bytes</div>
            <div class="text-2xl font-bold text-gray-900 dark:text-gray-100">
              {format_bytes(@stats.bytes_captured)}
            </div>
          </div>
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Rate</div>
            <div class="text-2xl font-bold text-gray-900 dark:text-gray-100">
              {@stats.capture_rate} pkt/s
            </div>
          </div>
          <div>
            <div class="text-sm text-gray-600 dark:text-gray-400">Bandwidth</div>
            <div class="text-2xl font-bold text-gray-900 dark:text-gray-100">
              {@stats.bandwidth_mbps} Mbps
            </div>
          </div>
        </div>
      </div>

      <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-4 mb-4">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <button
              phx-click="clear_packets"
              class="px-3 py-2 text-sm bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 text-gray-800 dark:text-gray-200 rounded-lg transition"
            >
              Clear Packets
            </button>
            <button
              phx-click="export_pcap"
              class="px-3 py-2 text-sm bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition"
              disabled={length(@packets) == 0}
            >
              Export PCAP
            </button>
          </div>
          <div class="text-sm text-gray-600 dark:text-gray-400">
            Showing {length(@packets)} / {@options.max_packets} packets
          </div>
        </div>
      </div>

      <div class="bg-white dark:bg-gray-800 rounded-lg shadow-lg overflow-hidden">
        <div class="overflow-x-auto">
          <table class="w-full">
            <thead class="bg-gray-100 dark:bg-gray-900 sticky top-0 z-10">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                  #
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                  Timestamp
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                  Source
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                  Destination
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                  Protocol
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                  Length
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                  Info
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200 dark:divide-gray-700">
              <%= for {packet, index} <- Enum.with_index(filtered_packets(@packets, @display_filter)) do %>
                <tr
                  phx-click="select_packet"
                  phx-value-packet_id={packet.id}
                  class={"cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700 transition #{if @selected_packet && @selected_packet.id == packet.id, do: "bg-blue-50 dark:bg-blue-900"}"}
                >
                  <td class="px-4 py-3 text-sm text-gray-900 dark:text-gray-100">
                    {index + 1}
                  </td>
                  <td class="px-4 py-3 text-sm font-mono text-gray-700 dark:text-gray-300">
                    {format_timestamp(packet.timestamp)}
                  </td>
                  <td class="px-4 py-3 text-sm font-mono text-gray-900 dark:text-gray-100">
                    {packet.source_ip}:{packet.source_port}
                  </td>
                  <td class="px-4 py-3 text-sm font-mono text-gray-900 dark:text-gray-100">
                    {packet.dest_ip}:{packet.dest_port}
                  </td>
                  <td class="px-4 py-3 text-sm">
                    <span class={"px-2 py-1 rounded-full text-xs font-medium #{protocol_badge_class(packet.protocol)}"}>
                      {packet.protocol |> to_string() |> String.upcase()}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-900 dark:text-gray-100">
                    {packet.length} bytes
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-700 dark:text-gray-300">
                    {packet_info(packet)}
                  </td>
                </tr>
              <% end %>
              <%= if length(@packets) == 0 do %>
                <tr>
                  <td colspan="7" class="px-4 py-8 text-center text-gray-500 dark:text-gray-400">
                    No packets captured yet. Click "Start Capture" to begin.
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <%= if @selected_packet do %>
        <div class="mt-4 bg-white dark:bg-gray-800 rounded-lg shadow-lg p-6">
          <h2 class="text-xl font-bold text-gray-900 dark:text-gray-100 mb-4">
            Packet Details
          </h2>
          <div class="space-y-4">
            <details class="group" open>
              <summary class="flex items-center gap-2 cursor-pointer font-medium text-gray-900 dark:text-gray-100">
                <span class="group-open:rotate-90 transition-transform">▶</span> Ethernet II
              </summary>
              <div class="ml-6 mt-2 text-sm text-gray-700 dark:text-gray-300 space-y-1">
                <div>
                  Source MAC:
                  <code class="px-2 py-1 bg-gray-100 dark:bg-gray-900 rounded">
                    00:00:00:00:00:00
                  </code>
                </div>
                <div>
                  Dest MAC:
                  <code class="px-2 py-1 bg-gray-100 dark:bg-gray-900 rounded">
                    00:00:00:00:00:00
                  </code>
                </div>
                <div>
                  Type:
                  <code class="px-2 py-1 bg-gray-100 dark:bg-gray-900 rounded">IPv4 (0x0800)</code>
                </div>
              </div>
            </details>

            <details class="group" open>
              <summary class="flex items-center gap-2 cursor-pointer font-medium text-gray-900 dark:text-gray-100">
                <span class="group-open:rotate-90 transition-transform">▶</span>
                Internet Protocol (IPv4)
              </summary>
              <div class="ml-6 mt-2 text-sm text-gray-700 dark:text-gray-300 space-y-1">
                <div>
                  Source:
                  <code class="px-2 py-1 bg-gray-100 dark:bg-gray-900 rounded">
                    {@selected_packet.source_ip}
                  </code>
                </div>
                <div>
                  Destination:
                  <code class="px-2 py-1 bg-gray-100 dark:bg-gray-900 rounded">
                    {@selected_packet.dest_ip}
                  </code>
                </div>
                <div>Length: {@selected_packet.length} bytes</div>
              </div>
            </details>

            <details class="group" open>
              <summary class="flex items-center gap-2 cursor-pointer font-medium text-gray-900 dark:text-gray-100">
                <span class="group-open:rotate-90 transition-transform">▶</span>
                {@selected_packet.protocol |> to_string() |> String.upcase()}
              </summary>
              <div class="ml-6 mt-2 text-sm text-gray-700 dark:text-gray-300 space-y-1">
                <div>Source Port: {@selected_packet.source_port}</div>
                <div>Dest Port: {@selected_packet.dest_port}</div>
                <%= if @selected_packet.flags != %{} do %>
                  <div>
                    Flags:
                    <%= for {flag, value} <- @selected_packet.flags do %>
                      <%= if value do %>
                        <span class="px-2 py-1 bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 rounded text-xs">
                          {flag |> to_string() |> String.upcase()}
                        </span>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
                <%= if @selected_packet.dissected != %{} do %>
                  <%= for {key, value} <- @selected_packet.dissected do %>
                    <div>{key}: {inspect(value)}</div>
                  <% end %>
                <% end %>
              </div>
            </details>

            <%= if @selected_packet.payload do %>
              <details class="group">
                <summary class="flex items-center gap-2 cursor-pointer font-medium text-gray-900 dark:text-gray-100">
                  <span class="group-open:rotate-90 transition-transform">▶</span>
                  Payload ({byte_size(@selected_packet.payload)} bytes)
                </summary>
                <div class="ml-6 mt-2">
                  <pre class="text-xs font-mono text-gray-700 dark:text-gray-300 bg-gray-50 dark:bg-gray-900 p-4 rounded overflow-x-auto"><%= format_hexdump(@selected_packet.payload) %></pre>
                </div>
              </details>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp stream_packets(capture_pid, machine_id) do
    ref = Process.monitor(capture_pid)

    stream_loop(capture_pid, machine_id, ref)
  end

  defp stream_loop(capture_pid, machine_id, ref) do
    receive do
      {:DOWN, ^ref, :process, ^capture_pid, _reason} ->
        Phoenix.PubSub.broadcast(
          PhoenixUi.PubSub,
          "network_capture:#{machine_id}",
          {:capture_stopped, :normal}
        )

      other ->
        Logger.debug("Unexpected message in stream_loop: #{inspect(other)}")
        stream_loop(capture_pid, machine_id, ref)
    after
      100 ->
        stream_loop(capture_pid, machine_id, ref)
    end
  end

  defp serialize_packet(packet) do
    %{
      id: packet.id,
      timestamp: DateTime.to_iso8601(packet.timestamp),
      source_ip: packet.source_ip,
      dest_ip: packet.dest_ip,
      source_port: packet.source_port,
      dest_port: packet.dest_port,
      protocol: packet.protocol,
      length: packet.length,
      flags: packet.flags,
      dissected: packet.dissected,
      payload: if(packet.payload, do: Base.encode64(packet.payload), else: nil)
    }
  end

  defp map_flows(flows) when is_list(flows) do
    flows
    |> Enum.map(fn flow -> {flow.flow_id, flow} end)
    |> Map.new()
  end

  defp map_flows(flows), do: flows

  defp filtered_packets(packets, %{protocol: nil, source_ip: nil, dest_ip: nil}), do: packets

  defp filtered_packets(packets, filter) do
    Enum.filter(packets, fn packet ->
      protocol_match = is_nil(filter.protocol) || packet.protocol == filter.protocol
      source_match = is_nil(filter.source_ip) || packet.source_ip == filter.source_ip
      dest_match = is_nil(filter.dest_ip) || packet.dest_ip == filter.dest_ip

      protocol_match && source_match && dest_match
    end)
  end

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0..11)
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp protocol_badge_class(:http),
    do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"

  defp protocol_badge_class(:https),
    do: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200"

  defp protocol_badge_class(:dns),
    do: "bg-purple-100 text-purple-800 dark:bg-purple-900 dark:text-purple-200"

  defp protocol_badge_class(:ssh),
    do: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200"

  defp protocol_badge_class(:tcp),
    do: "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200"

  defp protocol_badge_class(:udp),
    do: "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200"

  defp protocol_badge_class(_),
    do: "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200"

  defp packet_info(packet) do
    case packet do
      %{protocol: :http} -> "HTTP Request"
      %{protocol: :https} -> "TLS Handshake"
      %{protocol: :dns} -> "DNS Query"
      %{protocol: :ssh} -> "SSH Connection"
      %{protocol: :tcp, flags: %{syn: true, ack: false}} -> "TCP SYN (Connection Attempt)"
      %{protocol: :tcp, flags: %{syn: true, ack: true}} -> "TCP SYN-ACK"
      %{protocol: :tcp, flags: %{fin: true}} -> "TCP FIN (Connection Close)"
      %{protocol: :tcp, flags: %{rst: true}} -> "TCP RST (Connection Reset)"
      %{protocol: :tcp} -> "TCP Data"
      %{protocol: :udp} -> "UDP Datagram"
      _ -> ""
    end
  end

  defp format_hexdump(binary) when byte_size(binary) == 0, do: "(empty)"

  defp format_hexdump(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(16)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      offset = String.pad_leading(Integer.to_string(index * 16, 16), 4, "0")

      hex =
        chunk
        |> Enum.map(&String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
        |> Enum.join(" ")

      ascii = chunk |> Enum.map(&printable_char/1) |> Enum.join()

      "#{offset}  #{String.pad_trailing(hex, 47)}  #{ascii}"
    end)
    |> Enum.join("\n")
  end

  defp printable_char(byte) when byte >= 32 and byte <= 126, do: <<byte>>
  defp printable_char(_), do: "."
end
