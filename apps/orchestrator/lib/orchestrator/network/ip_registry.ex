defmodule Orchestrator.Network.IPRegistry do
  use GenServer
  require Logger

  @table_name :ip_registry
  @pubsub Orchestrator.PubSub

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(String.t(), String.t(), String.t(), atom()) :: :ok
  def register(ipv6, machine_id, region, node_name) do
    GenServer.call(__MODULE__, {:register, ipv6, machine_id, region, node_name})
  end

  @spec lookup(String.t()) :: {:ok, {String.t(), String.t(), atom()}} | {:error, :not_found}
  def lookup(ipv6) do
    case :ets.lookup(@table_name, ipv6) do
      [{^ipv6, machine_id, region, node_name, _last_seen}] ->
        {:ok, {machine_id, region, node_name}}

      [] ->
        {:error, :not_found}
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(ipv6) do
    GenServer.call(__MODULE__, {:delete, ipv6})
  end

  @spec all() :: list({String.t(), String.t(), String.t(), atom(), DateTime.t()})
  def all do
    :ets.tab2list(@table_name)
  end

  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table_name, :size)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    Phoenix.PubSub.subscribe(@pubsub, "ip_registry")

    Logger.info("IP Registry started", table: @table_name, node: node())

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, ipv6, machine_id, region, node_name}, _from, state) do
    entry = {ipv6, machine_id, region, node_name, DateTime.utc_now()}
    :ets.insert(@table_name, entry)

    Logger.debug("IP registered",
      ipv6: ipv6,
      machine_id: machine_id,
      region: region,
      node: node_name
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "ip_registry",
      {:register, ipv6, machine_id, region, node_name}
    )

    :telemetry.execute(
      [:orchestrator, :network, :ip_registered],
      %{},
      %{ipv6: ipv6, machine_id: machine_id, region: region}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, ipv6}, _from, state) do
    :ets.delete(@table_name, ipv6)

    Logger.debug("IP deleted", ipv6: ipv6)

    Phoenix.PubSub.broadcast(@pubsub, "ip_registry", {:delete, ipv6})

    :telemetry.execute(
      [:orchestrator, :network, :ip_deleted],
      %{},
      %{ipv6: ipv6}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:register, ipv6, machine_id, region, node_name}, state) do
    entry = {ipv6, machine_id, region, node_name, DateTime.utc_now()}
    :ets.insert(@table_name, entry)

    Logger.debug("IP registered (remote)",
      ipv6: ipv6,
      machine_id: machine_id,
      region: region,
      node: node_name
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:delete, ipv6}, state) do
    :ets.delete(@table_name, ipv6)

    Logger.debug("IP deleted (remote)", ipv6: ipv6)

    {:noreply, state}
  end
end
