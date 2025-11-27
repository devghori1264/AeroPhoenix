defmodule Orchestrator.Debugger.NetworkCapture do
  import Bitwise
  use GenServer
  require Logger

  @type capture_options :: %{
          interface: String.t(),
          filter: String.t() | nil,
          max_packets: integer() | :unlimited,
          max_size_mb: integer() | :unlimited,
          protocols: list(atom()),
          full_payload: boolean(),
          tls_keylog: boolean()
        }
  @type packet :: %{
          timestamp: DateTime.t(),
          source_ip: String.t(),
          dest_ip: String.t(),
          source_port: integer(),
          dest_port: integer(),
          protocol: atom(),
          length: integer(),
          payload: binary() | nil,
          flags: map(),
          dissected: map()
        }
  @type flow :: %{
          flow_id: String.t(),
          source_ip: String.t(),
          dest_ip: String.t(),
          source_port: integer(),
          dest_port: integer(),
          protocol: atom(),
          packets: integer(),
          bytes: integer(),
          start_time: DateTime.t(),
          last_seen: DateTime.t(),
          state: atom()
        }
  defstruct [
    :machine_id,
    :port,
    :options,
    packets: [],
    flows: %{},
    stats: %{
      packets_captured: 0,
      packets_dropped: 0,
      bytes_captured: 0
    },
    started_at: nil
  ]

  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(machine_id, opts \\ []) do
    options = %{
      interface: Keyword.get(opts, :interface, "eth0"),
      filter: Keyword.get(opts, :filter),
      max_packets: Keyword.get(opts, :max_packets, 10_000),
      max_size_mb: Keyword.get(opts, :max_size_mb, 100),
      protocols: Keyword.get(opts, :protocols, [:tcp, :udp]),
      full_payload: Keyword.get(opts, :full_payload, false),
      tls_keylog: Keyword.get(opts, :tls_keylog, false)
    }

    GenServer.start(__MODULE__, {machine_id, options})
  end

  @spec stop(pid()) :: {:ok, list(packet())} | {:error, term()}
  def stop(capture_pid) do
    GenServer.call(capture_pid, :stop)
  end

  @spec get_stats(pid()) :: {:ok, map()}
  def get_stats(capture_pid) do
    GenServer.call(capture_pid, :get_stats)
  end

  @spec get_flows(pid()) :: {:ok, list(flow())}
  def get_flows(capture_pid) do
    GenServer.call(capture_pid, :get_flows)
  end

  @spec export_pcap(pid(), Path.t()) :: :ok | {:error, term()}
  def export_pcap(capture_pid, path) do
    GenServer.call(capture_pid, {:export_pcap, path})
  end

  @spec filter_packets(pid(), map()) :: {:ok, list(packet())}
  def filter_packets(capture_pid, criteria) do
    GenServer.call(capture_pid, {:filter_packets, criteria})
  end

  @impl true
  def init({machine_id, options}) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      machine_id: machine_id,
      options: options,
      started_at: DateTime.utc_now()
    }

    {:ok, state, {:continue, :start_capture}}
  end

  @impl true
  def handle_continue(:start_capture, state) do
    case spawn_tcpdump(state) do
      {:ok, port} ->
        Logger.info("Network capture started",
          machine_id: state.machine_id,
          interface: state.options.interface
        )

        {:noreply, %{state | port: port}}

      {:error, reason} ->
        Logger.error("Failed to start network capture",
          machine_id: state.machine_id,
          reason: inspect(reason)
        )

        {:stop, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    stop_tcpdump(state.port)

    result = %{
      packets: Enum.reverse(state.packets),
      flows: Map.values(state.flows),
      stats: state.stats,
      duration_seconds: DateTime.diff(DateTime.utc_now(), state.started_at)
    }

    {:stop, :normal, {:ok, result}, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        flows: map_size(state.flows),
        duration_seconds: DateTime.diff(DateTime.utc_now(), state.started_at)
      })

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_call(:get_flows, _from, state) do
    flows = Map.values(state.flows)
    {:reply, {:ok, flows}, state}
  end

  @impl true
  def handle_call({:export_pcap, path}, _from, state) do
    case write_pcap_file(path, state.packets) do
      :ok ->
        Logger.info("Exported packets to PCAP",
          machine_id: state.machine_id,
          path: path,
          packets: length(state.packets)
        )

        {:reply, :ok, state}

      {:error, reason} = error ->
        Logger.error("Failed to export PCAP",
          machine_id: state.machine_id,
          reason: inspect(reason)
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:filter_packets, criteria}, _from, state) do
    filtered = filter_packets_by_criteria(state.packets, criteria)
    {:reply, {:ok, filtered}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case parse_packet(data, state.options) do
      {:ok, packet} ->
        new_state = process_packet(state, packet)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.debug("Failed to parse packet",
          machine_id: state.machine_id,
          reason: inspect(reason)
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("tcpdump exited",
      machine_id: state.machine_id,
      exit_status: status
    )

    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      stop_tcpdump(state.port)
    end

    Logger.info("Network capture terminated",
      machine_id: state.machine_id,
      packets_captured: state.stats.packets_captured
    )

    :ok
  end

  defp spawn_tcpdump(state) do
    args = build_tcpdump_args(state.options)
    wrapper_script = Application.app_dir(:orchestrator, "priv/network_capture")

    try do
      port =
        Port.open(
          {:spawn_executable, wrapper_script},
          [
            :binary,
            :exit_status,
            {:args, ["--machine-id", state.machine_id | args]},
            {:packet, 4},
            {:env,
             [
               {~c"TCPDUMP_INTERFACE", String.to_charlist(state.options.interface)}
             ]}
          ]
        )

      {:ok, port}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp build_tcpdump_args(options) do
    args = [
      "-i",
      options.interface,
      "-n",
      "-U",
      "-w",
      "-",
      "-s",
      if(options.full_payload, do: "65535", else: "256")
    ]

    args =
      if options.max_packets != :unlimited do
        args ++ ["-c", Integer.to_string(options.max_packets)]
      else
        args
      end

    if options.filter do
      args ++ [options.filter]
    else
      args
    end
  end

  defp stop_tcpdump(nil), do: :ok

  defp stop_tcpdump(port) when is_port(port) do
    Port.command(port, <<0::32>>)
    Process.sleep(100)

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  defp parse_packet(raw_data, options) do
    case parse_pcap_packet(raw_data) do
      {:ok, packet_data} ->
        packet = dissect_packet(packet_data, options)
        {:ok, packet}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_pcap_packet(<<
         timestamp_sec::32-little,
         timestamp_usec::32-little,
         included_len::32-little,
         original_len::32-little,
         packet_data::binary-size(included_len)
       >>) do
    timestamp = DateTime.from_unix!(timestamp_sec * 1_000_000 + timestamp_usec, :microsecond)

    {:ok,
     %{
       timestamp: timestamp,
       length: original_len,
       data: packet_data
     }}
  end

  defp parse_pcap_packet(_), do: {:error, :invalid_format}

  defp dissect_packet(packet_data, options) do
    <<
      _dest_mac::binary-size(6),
      _source_mac::binary-size(6),
      ether_type::16,
      ip_packet::binary
    >> = packet_data.data

    if ether_type == 0x0800 do
      dissect_ipv4(packet_data, ip_packet, options)
    else
      %{
        timestamp: packet_data.timestamp,
        source_ip: "unknown",
        dest_ip: "unknown",
        source_port: 0,
        dest_port: 0,
        protocol: :other,
        length: packet_data.length,
        payload: nil,
        flags: %{},
        dissected: %{}
      }
    end
  end

  defp dissect_ipv4(packet_data, ip_packet, options) do
    <<
      version_ihl::8,
      _tos::8,
      total_len::16,
      _id::16,
      _flags_offset::16,
      _ttl::8,
      protocol::8,
      _checksum::16,
      source_ip::32,
      dest_ip::32,
      ip_payload::binary
    >> = ip_packet

    ihl = (version_ihl &&& 0x0F) * 4
    ip_options_size = ihl - 20
    <<_ip_options::binary-size(ip_options_size), transport_packet::binary>> = ip_payload
    source_ip_str = format_ipv4(source_ip)
    dest_ip_str = format_ipv4(dest_ip)

    {source_port, dest_port, transport_proto, flags, dissected} =
      case protocol do
        6 -> dissect_tcp(transport_packet)
        17 -> dissect_udp(transport_packet)
        1 -> {0, 0, :icmp, %{}, %{}}
        _ -> {0, 0, :other, %{}, %{}}
      end

    payload =
      if options.full_payload do
        extract_payload(transport_packet, transport_proto)
      else
        nil
      end

    %{
      timestamp: packet_data.timestamp,
      source_ip: source_ip_str,
      dest_ip: dest_ip_str,
      source_port: source_port,
      dest_port: dest_port,
      protocol: transport_proto,
      length: total_len,
      payload: payload,
      flags: flags,
      dissected: dissected
    }
  end

  defp format_ipv4(ip_int) do
    <<a, b, c, d>> = <<ip_int::32>>
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp dissect_tcp(<<
         source_port::16,
         dest_port::16,
         seq::32,
         ack::32,
         data_offset_flags::16,
         window::16,
         _checksum::16,
         _urgent::16,
         _rest::binary
       >>) do
    data_offset = (data_offset_flags >>> 12) * 4

    flags = %{
      fin: (data_offset_flags &&& 0x01) != 0,
      syn: (data_offset_flags &&& 0x02) != 0,
      rst: (data_offset_flags &&& 0x04) != 0,
      psh: (data_offset_flags &&& 0x08) != 0,
      ack: (data_offset_flags &&& 0x10) != 0,
      urg: (data_offset_flags &&& 0x20) != 0
    }

    dissected = %{
      seq_num: seq,
      ack_num: ack,
      window_size: window,
      header_length: data_offset
    }

    app_proto = detect_application_protocol(source_port, dest_port, :tcp)
    {source_port, dest_port, app_proto, flags, dissected}
  end

  defp dissect_tcp(_), do: {0, 0, :tcp, %{}, %{}}

  defp dissect_udp(<<
         source_port::16,
         dest_port::16,
         length::16,
         _checksum::16,
         _payload::binary
       >>) do
    dissected = %{
      length: length
    }

    app_proto = detect_application_protocol(source_port, dest_port, :udp)
    {source_port, dest_port, app_proto, %{}, dissected}
  end

  defp dissect_udp(_), do: {0, 0, :udp, %{}, %{}}

  defp detect_application_protocol(source_port, dest_port, base_proto) do
    cond do
      source_port == 80 or dest_port == 80 -> :http
      source_port == 443 or dest_port == 443 -> :https
      source_port == 53 or dest_port == 53 -> :dns
      source_port == 22 or dest_port == 22 -> :ssh
      source_port in 50000..50100 or dest_port in 50000..50100 -> :grpc
      true -> base_proto
    end
  end

  defp extract_payload(transport_packet, :tcp) do
    case transport_packet do
      <<_header::binary-size(20), payload::binary>> -> payload
      _ -> <<>>
    end
  end

  defp extract_payload(transport_packet, :udp) do
    case transport_packet do
      <<_header::binary-size(8), payload::binary>> -> payload
      _ -> <<>>
    end
  end

  defp extract_payload(_, _), do: <<>>

  defp process_packet(state, packet) do
    new_stats = %{
      packets_captured: state.stats.packets_captured + 1,
      packets_dropped: state.stats.packets_dropped,
      bytes_captured: state.stats.bytes_captured + packet.length
    }

    flow_id = generate_flow_id(packet)
    new_flows = update_flow(state.flows, flow_id, packet)
    new_packets = [packet | state.packets]
    limited_packets = Enum.take(new_packets, state.options.max_packets)
    %{state | packets: limited_packets, flows: new_flows, stats: new_stats}
  end

  defp generate_flow_id(packet) do
    endpoints =
      [
        {packet.source_ip, packet.source_port},
        {packet.dest_ip, packet.dest_port}
      ]
      |> Enum.sort()

    [{ip1, port1}, {ip2, port2}] = endpoints
    "#{ip1}:#{port1}<->#{ip2}:#{port2}:#{packet.protocol}"
  end

  defp update_flow(flows, flow_id, packet) do
    case Map.get(flows, flow_id) do
      nil ->
        flow = %{
          flow_id: flow_id,
          source_ip: packet.source_ip,
          dest_ip: packet.dest_ip,
          source_port: packet.source_port,
          dest_port: packet.dest_port,
          protocol: packet.protocol,
          packets: 1,
          bytes: packet.length,
          start_time: packet.timestamp,
          last_seen: packet.timestamp,
          state: determine_flow_state(packet)
        }

        Map.put(flows, flow_id, flow)

      existing_flow ->
        updated_flow = %{
          existing_flow
          | packets: existing_flow.packets + 1,
            bytes: existing_flow.bytes + packet.length,
            last_seen: packet.timestamp,
            state: update_flow_state(existing_flow.state, packet)
        }

        Map.put(flows, flow_id, updated_flow)
    end
  end

  defp determine_flow_state(%{protocol: :tcp, flags: %{syn: true, ack: false}}), do: :syn_sent
  defp determine_flow_state(%{protocol: :tcp, flags: %{syn: true, ack: true}}), do: :syn_ack
  defp determine_flow_state(%{protocol: :tcp}), do: :established
  defp determine_flow_state(_), do: :active
  defp update_flow_state(_current, %{protocol: :tcp, flags: %{fin: true}}), do: :closing
  defp update_flow_state(_current, %{protocol: :tcp, flags: %{rst: true}}), do: :reset
  defp update_flow_state(current, _), do: current

  defp filter_packets_by_criteria(packets, criteria) do
    Enum.filter(packets, fn packet ->
      Enum.all?(criteria, fn {key, value} ->
        case key do
          :source_ip -> packet.source_ip == value
          :dest_ip -> packet.dest_ip == value
          :source_port -> packet.source_port == value
          :dest_port -> packet.dest_port == value
          :protocol -> packet.protocol == value
          :min_length -> packet.length >= value
          :max_length -> packet.length <= value
          _ -> true
        end
      end)
    end)
  end

  defp write_pcap_file(path, packets) do
    pcap_header = <<
      0xA1B2C3D4::32-little,
      2::16-little,
      4::16-little,
      0::32-little,
      0::32-little,
      65535::32-little,
      1::32-little
    >>

    pcap_packets = Enum.map(packets, &packet_to_pcap/1)
    File.write(path, [pcap_header | pcap_packets])
  end

  defp packet_to_pcap(packet) do
    timestamp_sec = DateTime.to_unix(packet.timestamp)
    timestamp_usec = 0
    packet_data = <<>>

    <<
      timestamp_sec::32-little,
      timestamp_usec::32-little,
      byte_size(packet_data)::32-little,
      packet.length::32-little,
      packet_data::binary
    >>
  end
end
