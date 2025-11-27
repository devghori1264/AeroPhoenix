defmodule Orchestrator.RegionRegistry do
  use GenServer
  require Logger
  @type region_code :: String.t()
  @type region_info :: %{
          code: region_code(),
          name: String.t(),
          endpoint: String.t(),
          grpc_port: integer(),
          http_port: integer(),
          healthy: boolean(),
          last_health_check: DateTime.t(),
          capacity: %{
            max_machines: integer(),
            current_machines: integer(),
            utilization_percent: float()
          },
          metadata: %{
            location: String.t(),
            zone: String.t(),
            cost_multiplier: float(),
            compliance: list(String.t())
          }
        }
  @health_check_interval :timer.seconds(30)
  @latency_check_interval :timer.minutes(5)
  @capacity_refresh_interval :timer.seconds(15)
  @backoff_schedule [100, 200, 500, 1000, 2000, 5000, 10000]
  @regions [
    %{
      code: "us-east-1",
      name: "US East (N. Virginia)",
      endpoint: "http://flyd-sim-us-east-1",
      grpc_port: 50051,
      http_port: 8080,
      metadata: %{
        location: "Virginia, USA",
        zone: "us-east",
        cost_multiplier: 1.0,
        compliance: ["hipaa", "soc2", "gdpr"]
      }
    },
    %{
      code: "eu-west-1",
      name: "EU West (Ireland)",
      endpoint: "http://flyd-sim-eu-west-1",
      grpc_port: 50052,
      http_port: 8081,
      metadata: %{
        location: "Dublin, Ireland",
        zone: "eu-west",
        cost_multiplier: 1.15,
        compliance: ["gdpr", "soc2"]
      }
    },
    %{
      code: "ap-south-1",
      name: "Asia Pacific (Mumbai)",
      endpoint: "http://flyd-sim-ap-south-1",
      grpc_port: 50053,
      http_port: 8082,
      metadata: %{
        location: "Mumbai, India",
        zone: "ap-south",
        cost_multiplier: 0.9,
        compliance: ["soc2"]
      }
    }
  ]
  @latency_matrix %{
    {"us-east-1", "us-east-1"} => 1,
    {"us-east-1", "eu-west-1"} => 85,
    {"us-east-1", "ap-south-1"} => 165,
    {"eu-west-1", "us-east-1"} => 85,
    {"eu-west-1", "eu-west-1"} => 1,
    {"eu-west-1", "ap-south-1"} => 120,
    {"ap-south-1", "us-east-1"} => 165,
    {"ap-south-1", "eu-west-1"} => 120,
    {"ap-south-1", "ap-south-1"} => 1
  }
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list_regions() :: [region_info()]
  def list_regions do
    GenServer.call(__MODULE__, :list_regions)
  end

  @spec get_region(region_code()) :: {:ok, region_info()} | {:error, :not_found}
  def get_region(region_code) do
    GenServer.call(__MODULE__, {:get_region, region_code})
  end

  @spec select_region(keyword()) :: {:ok, region_code()} | {:error, term()}
  def select_region(opts \\ []) do
    GenServer.call(__MODULE__, {:select_region, opts})
  end

  @spec get_latency(region_code(), region_code()) :: integer()
  def get_latency(from_region, to_region) do
    GenServer.call(__MODULE__, {:get_latency, from_region, to_region})
  end

  @spec has_capacity?(region_code(), integer()) :: boolean()
  def has_capacity?(region_code, required_machines \\ 1) do
    GenServer.call(__MODULE__, {:has_capacity, region_code, required_machines})
  end

  @spec healthy_regions() :: [region_code()]
  def healthy_regions do
    GenServer.call(__MODULE__, :healthy_regions)
  end

  @impl true
  def init(_opts) do
    initial_state = %{
      regions: initialize_regions(),
      latency_matrix: @latency_matrix,
      last_health_check: nil,
      stats: %{
        total_health_checks: 0,
        failed_health_checks: 0
      }
    }

    schedule_health_check()
    schedule_capacity_refresh()
    schedule_latency_check()
    Logger.info("RegionRegistry initialized with #{length(@regions)} regions")
    {:ok, initial_state}
  end

  @impl true
  def handle_call(:list_regions, _from, state) do
    regions = Map.values(state.regions)
    {:reply, regions, state}
  end

  def handle_call({:get_region, code}, _from, state) do
    normalized_code =
      case code do
        "us-east" -> "us-east-1"
        "eu-west" -> "eu-west-1"
        "ap-south" -> "ap-south-1"
        c -> c
      end

    case Map.get(state.regions, normalized_code) do
      nil -> {:reply, {:error, :not_found}, state}
      region -> {:reply, {:ok, region}, state}
    end
  end

  def handle_call({:select_region, opts}, _from, state) do
    strategy = Keyword.get(opts, :strategy, :load_balance)
    target_location = Keyword.get(opts, :target_location)
    required_capacity = Keyword.get(opts, :required_capacity, 1)
    result = do_select_region(state, strategy, target_location, required_capacity)
    {:reply, result, state}
  end

  def handle_call({:get_latency, from, to}, _from, state) do
    latency = Map.get(state.latency_matrix, {from, to}, 999_999)
    {:reply, latency, state}
  end

  def handle_call({:has_capacity, region_code, required}, _from, state) do
    result =
      case Map.get(state.regions, region_code) do
        nil ->
          false

        region ->
          available = region.capacity.max_machines - region.capacity.current_machines
          available >= required
      end

    {:reply, result, state}
  end

  def handle_call(:healthy_regions, _from, state) do
    regions =
      state.regions
      |> Map.values()
      |> Enum.filter(& &1.healthy)
      |> Enum.sort_by(& &1.capacity.utilization_percent)
      |> Enum.map(& &1.code)

    {:reply, regions, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    Logger.debug("Running health checks for all regions")
    new_state = perform_health_checks(state)
    schedule_health_check()
    {:noreply, new_state}
  end

  def handle_info(:capacity_refresh, state) do
    new_state = refresh_capacity(state)
    schedule_capacity_refresh()
    {:noreply, new_state}
  end

  def handle_info(:latency_check, state) do
    new_state = measure_latencies(state)
    schedule_latency_check()
    {:noreply, new_state}
  end

  defp initialize_regions do
    @regions
    |> Enum.map(fn config ->
      region = %{
        code: config.code,
        name: config.name,
        endpoint: config.endpoint,
        grpc_port: config.grpc_port,
        http_port: config.http_port,
        healthy: false,
        last_health_check: nil,
        capacity: %{
          max_machines: 100,
          current_machines: 0,
          utilization_percent: 0.0
        },
        metadata: config.metadata
      }

      {config.code, region}
    end)
    |> Map.new()
  end

  defp perform_health_checks(state) do
    start_time = System.monotonic_time(:millisecond)

    updated_regions =
      state.regions
      |> Enum.map(fn {code, region} ->
        health_status = check_region_health(region)
        updated_region = %{region | healthy: health_status, last_health_check: DateTime.utc_now()}

        if health_status do
          Logger.debug("Region #{code} healthy")
        else
          Logger.warning("Region #{code} unhealthy")
        end

        {code, updated_region}
      end)
      |> Map.new()

    duration = System.monotonic_time(:millisecond) - start_time
    Logger.info("Health checks completed in #{duration}ms")

    %{
      state
      | regions: updated_regions,
        last_health_check: DateTime.utc_now(),
        stats: %{state.stats | total_health_checks: state.stats.total_health_checks + 1}
    }
  end

  defp check_region_health(region) do
    if Application.get_env(:orchestrator, :env) == :dev do
      true
    else
      url = "#{region.endpoint}:#{region.http_port}/ping"

      case Finch.build(:get, url) |> Finch.request(Orchestrator.Finch, receive_timeout: 3_000) do
        {:ok, %{status: 200}} -> true
        _ -> false
      end
    end
  rescue
    _ -> false
  end

  def get_backoff(attempt) do
    Enum.at(@backoff_schedule, attempt, List.last(@backoff_schedule))
  end

  defp refresh_capacity(state) do
    state
  end

  defp measure_latencies(state) do
    state
  end

  defp do_select_region(state, strategy, target_location, required_capacity) do
    healthy =
      state.regions
      |> Map.values()
      |> Enum.filter(& &1.healthy)

    if Enum.empty?(healthy) do
      {:error, :no_healthy_regions}
    else
      selected =
        case strategy do
          :load_balance -> select_least_loaded(healthy, required_capacity)
          :cost -> select_cheapest(healthy, required_capacity)
          :latency -> select_lowest_latency(healthy, target_location, state.latency_matrix)
          :availability -> select_most_available(healthy, required_capacity)
          _ -> select_least_loaded(healthy, required_capacity)
        end

      case selected do
        nil -> {:error, :no_suitable_region}
        region -> {:ok, region.code}
      end
    end
  end

  defp select_least_loaded(regions, required_capacity) do
    regions
    |> Enum.filter(fn r ->
      available = r.capacity.max_machines - r.capacity.current_machines
      available >= required_capacity
    end)
    |> Enum.min_by(& &1.capacity.utilization_percent, fn -> nil end)
  end

  defp select_cheapest(regions, required_capacity) do
    regions
    |> Enum.filter(fn r ->
      available = r.capacity.max_machines - r.capacity.current_machines
      available >= required_capacity
    end)
    |> Enum.min_by(& &1.metadata.cost_multiplier, fn -> nil end)
  end

  defp select_lowest_latency(regions, target_location, _latency_matrix)
       when is_nil(target_location) do
    select_least_loaded(regions, 1)
  end

  defp select_lowest_latency(regions, target_location, latency_matrix) do
    regions
    |> Enum.map(fn region ->
      latency = Map.get(latency_matrix, {region.code, target_location}, 999_999)
      {region, latency}
    end)
    |> Enum.min_by(fn {_region, latency} -> latency end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp select_most_available(regions, required_capacity) do
    regions
    |> Enum.map(fn region ->
      available = region.capacity.max_machines - region.capacity.current_machines
      {region, available}
    end)
    |> Enum.filter(fn {_region, available} -> available >= required_capacity end)
    |> Enum.max_by(fn {_region, available} -> available end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp schedule_capacity_refresh do
    Process.send_after(self(), :capacity_refresh, @capacity_refresh_interval)
  end

  defp schedule_latency_check do
    Process.send_after(self(), :latency_check, @latency_check_interval)
  end
end
