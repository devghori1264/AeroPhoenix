defmodule Orchestrator.Replication.Coordinator do
  use GenServer
  require Logger
  alias Orchestrator.Replication.{RaftConsensus, StateSync, RegionReplica}
  @type region_info :: map()
  defmodule State do
    @moduledoc false
    defstruct [
      :regions,
      :leader_region,
      :replication_mode,
      :health_check_interval,
      :max_lag_threshold
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register_region(region, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:register_region, region, metadata})
  end

  def unregister_region(region) do
    GenServer.call(__MODULE__, {:unregister_region, region})
  end

  def get_leader do
    GenServer.call(__MODULE__, :get_leader)
  end

  def get_region_status do
    GenServer.call(__MODULE__, :get_region_status)
  end

  def trigger_election do
    GenServer.cast(__MODULE__, :trigger_election)
  end

  def set_replication_mode(mode) when mode in [:async, :sync, :semi_sync] do
    GenServer.call(__MODULE__, {:set_replication_mode, mode})
  end

  @impl true
  def init(opts) do
    health_check_interval = Keyword.get(opts, :health_check_interval, 5_000)
    max_lag_threshold = Keyword.get(opts, :max_lag_threshold, 1_000)
    replication_mode = Keyword.get(opts, :replication_mode, :async)

    state = %State{
      regions: %{},
      leader_region: nil,
      replication_mode: replication_mode,
      health_check_interval: health_check_interval,
      max_lag_threshold: max_lag_threshold
    }

    schedule_health_check(health_check_interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:register_region, region, metadata}, _from, state) do
    region_info = %{
      region: region,
      status: :healthy,
      last_heartbeat: DateTime.utc_now(),
      lag_ms: 0,
      is_leader: false,
      metadata: metadata
    }

    new_regions = Map.put(state.regions, region, region_info)
    new_state = %{state | regions: new_regions}

    if state.leader_region == nil do
      new_state = elect_leader(new_state)
    end

    Logger.info("Region registered: #{region}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unregister_region, region}, _from, state) do
    new_regions = Map.delete(state.regions, region)
    new_state = %{state | regions: new_regions}

    new_state =
      if state.leader_region == region do
        elect_leader(%{new_state | leader_region: nil})
      else
        new_state
      end

    Logger.warning("Region unregistered: #{region}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_leader, _from, state) do
    {:reply, state.leader_region, state}
  end

  @impl true
  def handle_call(:get_region_status, _from, state) do
    {:reply, state.regions, state}
  end

  @impl true
  def handle_call({:set_replication_mode, mode}, _from, state) do
    Logger.info("Replication mode changed: #{state.replication_mode} -> #{mode}")
    {:reply, :ok, %{state | replication_mode: mode}}
  end

  @impl true
  def handle_cast(:trigger_election, state) do
    new_state = elect_leader(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = perform_health_checks(state)
    schedule_health_check(state.health_check_interval)
    {:noreply, new_state}
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end

  defp perform_health_checks(state) do
    now = DateTime.utc_now()

    new_regions =
      Enum.reduce(state.regions, state.regions, fn {region, info}, acc ->
        lag = measure_replication_lag(region)
        time_since_heartbeat = DateTime.diff(now, info.last_heartbeat, :millisecond)

        status =
          cond do
            time_since_heartbeat > 30_000 -> :failed
            lag > state.max_lag_threshold -> :degraded
            true -> :healthy
          end

        updated_info = %{info | lag_ms: lag, status: status, last_heartbeat: now}
        Map.put(acc, region, updated_info)
      end)

    new_state = %{state | regions: new_regions}

    if state.leader_region != nil do
      leader_info = new_regions[state.leader_region]

      if leader_info && leader_info.status == :failed do
        Logger.warning("Leader #{state.leader_region} failed, triggering election")
        elect_leader(%{new_state | leader_region: nil})
      else
        new_state
      end
    else
      elect_leader(new_state)
    end
  end

  defp measure_replication_lag(region) do
    case region do
      "us-east-1" -> :rand.uniform(10)
      "us-west-1" -> :rand.uniform(20)
      "eu-west-1" -> :rand.uniform(50)
      "ap-south-1" -> :rand.uniform(100)
      _ -> :rand.uniform(30)
    end
  end

  defp elect_leader(state) do
    candidate =
      state.regions
      |> Enum.filter(fn {_region, info} -> info.status == :healthy end)
      |> Enum.min_by(fn {_region, info} -> info.lag_ms end, fn -> nil end)

    case candidate do
      {region, _info} ->
        new_regions =
          state.regions
          |> Enum.map(fn {r, info} ->
            {r, %{info | is_leader: r == region}}
          end)
          |> Enum.into(%{})

        Logger.info("New leader elected: #{region}")

        :telemetry.execute(
          [:orchestrator, :replication, :leader_elected],
          %{count: 1},
          %{region: region}
        )

        %{state | leader_region: region, regions: new_regions}

      nil ->
        Logger.error("No healthy regions available for leader election")
        state
    end
  end
end
