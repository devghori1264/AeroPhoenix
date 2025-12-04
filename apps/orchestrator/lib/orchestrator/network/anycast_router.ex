defmodule Orchestrator.Network.AnycastRouter do
  use GenServer
  require Logger

  alias Orchestrator.Network.IPRegistry

  @table_name :anycast_routes

  @as_numbers %{
    "iad" => 64512,
    "ord" => 64513,
    "sjc" => 64514,
    "lhr" => 64515,
    "syd" => 64516,
    "fra" => 64517,
    "nrt" => 64518
  }

  @as_distances %{
    {"iad", "ord"} => 1,
    {"ord", "iad"} => 1,
    {"ord", "sjc"} => 2,
    {"sjc", "ord"} => 2,
    {"iad", "sjc"} => 3,
    {"sjc", "iad"} => 3,
    {"iad", "lhr"} => 3,
    {"lhr", "iad"} => 3,
    {"ord", "lhr"} => 4,
    {"lhr", "ord"} => 4,
    {"sjc", "nrt"} => 4,
    {"nrt", "sjc"} => 4,
    {"iad", "syd"} => 7,
    {"syd", "iad"} => 7,
    {"lhr", "nrt"} => 5,
    {"nrt", "lhr"} => 5,
    {"fra", "syd"} => 6,
    {"syd", "fra"} => 6
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec announce_route(String.t(), String.t(), String.t()) :: :ok
  def announce_route(ipv6, machine_id, region) do
    GenServer.call(__MODULE__, {:announce, ipv6, machine_id, region})
  end

  @spec withdraw_route(String.t(), String.t()) :: :ok
  def withdraw_route(ipv6, region) do
    GenServer.call(__MODULE__, {:withdraw, ipv6, region})
  end

  @spec get_routes() :: list({String.t(), String.t(), String.t(), list(non_neg_integer())})
  def get_routes do
    :ets.tab2list(@table_name)
  end

  @spec as_path_length(String.t(), String.t()) :: non_neg_integer()
  def as_path_length(from_region, to_region) do
    if from_region == to_region do
      0
    else
      Map.get(@as_distances, {from_region, to_region}, 10)
    end
  end

  @spec find_nearest(String.t(), String.t()) :: {:ok, String.t()} | {:error, :no_routes}
  def find_nearest(ipv6, client_region) do
    announcements =
      :ets.match(@table_name, {ipv6, :"$1", :"$2", :"$3", :announced})
      |> Enum.map(fn [machine_id, region, node] -> {machine_id, region, node} end)

    if Enum.empty?(announcements) do
      {:error, :no_routes}
    else
      {_machine_id, nearest_region, _node} =
        Enum.min_by(announcements, fn {_mid, region, _node} ->
          as_path_length(client_region, region)
        end)

      {:ok, nearest_region}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [
      :bag,
      :named_table,
      :public,
      read_concurrency: true
    ])

    Logger.debug("Anycast Router started", table: @table_name)

    {:ok, %{}}
  end

  @impl true
  def handle_call({:announce, ipv6, machine_id, region}, _from, state) do
    as_path = [Map.get(@as_numbers, region, 64999)]

    :ets.insert(@table_name, {ipv6, machine_id, region, node(), :announced})

    Logger.debug("BGP ANNOUNCE",
      ipv6: ipv6,
      machine_id: machine_id,
      region: region,
      as_path: as_path
    )

    IPRegistry.register(ipv6, machine_id, region, node())

    :telemetry.execute(
      [:orchestrator, :network, :route_announced],
      %{},
      %{ipv6: ipv6, machine_id: machine_id, region: region}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:withdraw, ipv6, region}, _from, state) do
    announcements = :ets.match(@table_name, {ipv6, :"$1", region, :"$2", :announced})

    Enum.each(announcements, fn [machine_id, node_name] ->
      :ets.delete_object(@table_name, {ipv6, machine_id, region, node_name, :announced})
    end)

    Logger.debug("BGP WITHDRAW", ipv6: ipv6, region: region)

    remaining = :ets.match(@table_name, {ipv6, :"$1", :"$2", :"$3", :announced})

    if Enum.empty?(remaining) do
      IPRegistry.delete(ipv6)
    end

    :telemetry.execute(
      [:orchestrator, :network, :route_withdrawn],
      %{},
      %{ipv6: ipv6, region: region}
    )

    {:reply, :ok, state}
  end
end
