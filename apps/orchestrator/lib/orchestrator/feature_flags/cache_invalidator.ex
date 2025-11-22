defmodule Orchestrator.FeatureFlags.CacheInvalidator do
  use GenServer
  require Logger
  alias Orchestrator.FeatureFlags.{Distribution, Engine}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Distribution.subscribe_to_flag_updates()
    Distribution.subscribe_to_experiment_updates()
    Logger.info("CacheInvalidator started and subscribed to flag updates")
    {:ok, %{invalidation_count: 0}}
  end

  @impl true
  def handle_info(%{event: "flag_updated", flag_key: flag_key}, state) do
    Logger.debug("Received flag_updated event for: #{flag_key}")
    Engine.invalidate_cache(flag_key)
    {:noreply, %{state | invalidation_count: state.invalidation_count + 1}}
  end

  def handle_info(%{event: "flag_deleted", flag_key: flag_key}, state) do
    Logger.debug("Received flag_deleted event for: #{flag_key}")
    Engine.invalidate_cache(flag_key)
    {:noreply, %{state | invalidation_count: state.invalidation_count + 1}}
  end

  def handle_info(%{event: "experiment_updated"}, state) do
    Logger.debug("Received experiment_updated event")
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end
end
