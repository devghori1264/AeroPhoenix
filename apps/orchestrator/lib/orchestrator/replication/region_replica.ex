defmodule Orchestrator.Replication.RegionReplica do
  use GenServer
  require Logger
  @lag_check_interval 10_000
  @max_acceptable_lag 5_000
  defmodule State do
    @moduledoc false
    defstruct [
      :region,
      :role,
      :leader_region,
      :replication_lag,
      :last_write_timestamp,
      :last_sync_timestamp,
      :statistics
    ]
  end

  def start_link(opts) do
    region = Keyword.fetch!(opts, :region)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(region))
  end

  def read(region, key, opts \\ []) do
    GenServer.call(via_tuple(region), {:read, key, opts})
  end

  def write(region, key, value, opts \\ []) do
    GenServer.call(via_tuple(region), {:write, key, value, opts})
  end

  def get_status(region) do
    GenServer.call(via_tuple(region), :get_status)
  end

  def promote_to_leader(region) do
    GenServer.cast(via_tuple(region), :promote_to_leader)
  end

  def demote_to_follower(region, leader_region) do
    GenServer.cast(via_tuple(region), {:demote_to_follower, leader_region})
  end

  @impl true
  def init(opts) do
    region = Keyword.fetch!(opts, :region)
    role = Keyword.get(opts, :role, :follower)
    leader_region = Keyword.get(opts, :leader_region)

    state = %State{
      region: region,
      role: role,
      leader_region: leader_region,
      replication_lag: 0,
      last_write_timestamp: DateTime.utc_now(),
      last_sync_timestamp: DateTime.utc_now(),
      statistics: %{
        reads: 0,
        writes: 0,
        forwarded_writes: 0,
        stale_reads: 0
      }
    }

    schedule_lag_check()
    {:ok, state}
  end

  @impl true
  def handle_call({:read, key, opts}, _from, state) do
    consistency = Keyword.get(opts, :consistency, :eventual)

    case consistency do
      :strong ->
        if state.role == :leader do
          result = perform_local_read(key)
          new_stats = %{state.statistics | reads: state.statistics.reads + 1}
          {:reply, result, %{state | statistics: new_stats}}
        else
          result = forward_read_to_leader(key, state.leader_region)
          {:reply, result, state}
        end

      :eventual ->
        if state.replication_lag <= @max_acceptable_lag do
          result = perform_local_read(key)
          new_stats = %{state.statistics | reads: state.statistics.reads + 1}
          {:reply, result, %{state | statistics: new_stats}}
        else
          result = perform_local_read(key)

          new_stats = %{
            state.statistics
            | reads: state.statistics.reads + 1,
              stale_reads: state.statistics.stale_reads + 1
          }

          {:reply, {:ok, result, :stale}, %{state | statistics: new_stats}}
        end

      _ ->
        {:reply, {:error, :invalid_consistency_level}, state}
    end
  end

  @impl true
  def handle_call({:write, key, value, _opts}, _from, %{role: :leader} = state) do
    result = perform_local_write(key, value)

    new_state = %{
      state
      | last_write_timestamp: DateTime.utc_now(),
        statistics: %{state.statistics | writes: state.statistics.writes + 1}
    }

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:write, key, value, opts}, _from, state) do
    result = forward_write_to_leader(key, value, state.leader_region, opts)
    new_stats = %{state.statistics | forwarded_writes: state.statistics.forwarded_writes + 1}
    {:reply, result, %{state | statistics: new_stats}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      region: state.region,
      role: state.role,
      leader_region: state.leader_region,
      replication_lag_ms: state.replication_lag,
      is_lagging: state.replication_lag > @max_acceptable_lag,
      last_write: state.last_write_timestamp,
      last_sync: state.last_sync_timestamp,
      statistics: state.statistics
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:promote_to_leader, state) do
    Logger.info("Replica #{state.region} promoted to leader")
    new_state = %{state | role: :leader, leader_region: state.region}

    :telemetry.execute(
      [:orchestrator, :replication, :promotion],
      %{count: 1},
      %{region: state.region}
    )

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:demote_to_follower, leader_region}, state) do
    Logger.info("Replica #{state.region} demoted to follower, leader is #{leader_region}")
    new_state = %{state | role: :follower, leader_region: leader_region}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_lag, state) do
    new_lag = measure_replication_lag(state)
    new_state = %{state | replication_lag: new_lag, last_sync_timestamp: DateTime.utc_now()}

    if new_lag > @max_acceptable_lag do
      Logger.warning("High replication lag in #{state.region}: #{new_lag}ms")

      :telemetry.execute(
        [:orchestrator, :replication, :high_lag],
        %{lag_ms: new_lag},
        %{region: state.region}
      )
    end

    schedule_lag_check()
    {:noreply, new_state}
  end

  defp via_tuple(region) do
    {:via, Registry, {Orchestrator.Registry, {:replica, region}}}
  end

  defp schedule_lag_check do
    Process.send_after(self(), :check_lag, @lag_check_interval)
  end

  defp perform_local_read(key) do
    :timer.sleep(:rand.uniform(5))
    {:ok, "value_for_#{key}"}
  end

  defp perform_local_write(key, value) do
    :timer.sleep(:rand.uniform(10))
    {:ok, "wrote_#{key}=#{value}"}
  end

  defp forward_read_to_leader(key, leader_region) do
    :timer.sleep(:rand.uniform(20))
    {:ok, "value_for_#{key}_from_leader_#{leader_region}"}
  end

  defp forward_write_to_leader(key, value, leader_region, _opts) do
    :timer.sleep(:rand.uniform(30))
    {:ok, "forwarded_write_#{key}=#{value}_to_leader_#{leader_region}"}
  end

  defp measure_replication_lag(state) do
    if state.role == :leader do
      0
    else
      base_lag = :rand.uniform(100)

      region_latency =
        case state.region do
          "us-east-1" -> 10
          "us-west-1" -> 20
          "eu-west-1" -> 50
          "ap-south-1" -> 100
          _ -> 30
        end

      base_lag + region_latency
    end
  end
end
