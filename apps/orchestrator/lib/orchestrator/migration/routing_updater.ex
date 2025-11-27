defmodule Orchestrator.Migration.RoutingUpdater do
  require Logger

  alias Orchestrator.Migration.RoutingTable

  @type machine_id :: String.t()
  @type ip_address :: String.t()
  @type region :: atom()

  @spec update_route(machine_id(), machine_id(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_route(source_machine, dest_machine, migration_id, opts \\ []) do
    verify_health = Keyword.get(opts, :verify_health, true)
    broadcast = Keyword.get(opts, :broadcast, true)

    Logger.info("Updating routing atomically",
      migration_id: migration_id,
      from: source_machine,
      to: dest_machine
    )

    machine_id = extract_machine_id(source_machine)

    dest_details = get_machine_details(dest_machine)

    if verify_health do
      case verify_destination_health(dest_details) do
        :ok ->
          :ok
      end
    end

    old_route = RoutingTable.lookup(machine_id)

    case RoutingTable.update(
           machine_id,
           dest_details.ip,
           dest_details.port,
           dest_details.region
         ) do
      :ok ->
        Logger.info("Routing updated",
          machine_id: machine_id,
          old: inspect(old_route),
          new: dest_details
        )

        if broadcast do
          broadcast_routing_update(machine_id, dest_details)
        end

        :telemetry.execute(
          [:orchestrator, :migration, :routing_updated],
          %{},
          %{
            migration_id: migration_id,
            machine_id: machine_id,
            old_region: extract_region(old_route),
            new_region: dest_details.region
          }
        )

        :ok
    end
  end

  @spec rollback_route(machine_id(), machine_id()) :: :ok | {:error, term()}
  def rollback_route(source_machine, migration_id) do
    machine_id = extract_machine_id(source_machine)

    Logger.warning("Rolling back routing update",
      migration_id: migration_id,
      machine_id: machine_id
    )

    source_details = get_machine_details(source_machine)

    case RoutingTable.update(
           machine_id,
           source_details.ip,
           source_details.port,
           source_details.region
         ) do
      :ok ->
        Logger.info("Routing rollback complete", machine_id: machine_id)

        :telemetry.execute(
          [:orchestrator, :migration, :routing_rollback],
          %{},
          %{migration_id: migration_id, machine_id: machine_id}
        )

        :ok
    end
  end

  defp extract_machine_id(machine_with_region) do
    machine_with_region
    |> String.split("_")
    |> Enum.take(2)
    |> Enum.join("_")
  end

  defp extract_region({:ok, route}), do: route.region
  defp extract_region(_), do: nil

  defp get_machine_details(machine_with_region) do
    parts = String.split(machine_with_region, "_")
    region = parts |> List.last() |> String.to_atom()

    ip = generate_ip_for_region(region)

    %{
      ip: ip,
      port: 8080,
      region: region
    }
  end

  defp generate_ip_for_region(region) do
    case region do
      :iad -> "192.168.1.10"
      :lhr -> "192.168.2.20"
      :nrt -> "192.168.3.30"
      :syd -> "192.168.4.40"
      _ -> "192.168.0.1"
    end
  end

  defp verify_destination_health(dest_details) do
    Logger.debug("Health check",
      ip: dest_details.ip,
      port: dest_details.port
    )

    Process.sleep(1)

    :ok
  end

  defp broadcast_routing_update(machine_id, dest_details) do
    Logger.debug("Broadcasting routing update",
      machine_id: machine_id,
      dest: dest_details
    )

    :ok
  end
end

defmodule Orchestrator.Migration.RoutingTable do
  @table_name :orchestrator_routing_table

  def init do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end

  def lookup(machine_id) do
    case :ets.lookup(@table_name, machine_id) do
      [{^machine_id, {ip, port, region}}] ->
        {:ok, %{ip: ip, port: port, region: region}}

      [] ->
        {:error, :not_found}
    end
  end

  def update(machine_id, ip, port, region) do
    :ets.insert(@table_name, {machine_id, {ip, port, region}})
    :ok
  end

  def delete(machine_id) do
    :ets.delete(@table_name, machine_id)
    :ok
  end

  def all do
    :ets.tab2list(@table_name)
  end
end
