defmodule Orchestrator.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Orchestrator Application...")
    Orchestrator.Migration.RoutingTable.init()
    :ets.new(:live_migrations, [:named_table, :public, :set, {:read_concurrency, true}])
    :ets.new(:checkpoints, [:named_table, :public, :set, {:read_concurrency, true}])

    children =
      [
        Orchestrator.Repo,
        {Phoenix.PubSub, name: Orchestrator.PubSub},
        {Finch, name: Orchestrator.Finch},
        {Registry, keys: :unique, name: Orchestrator.FSMRegistry},
        {Registry, keys: :unique, name: Orchestrator.MachineActorRegistry},
        {Registry, keys: :unique, name: Orchestrator.DebuggerRegistry},
        {Registry, keys: :unique, name: Orchestrator.Registry},
        {Registry, keys: :unique, name: Orchestrator.Registry.Machines},
        {Registry, keys: :unique, name: Orchestrator.LiveMigrationRegistry},
        Orchestrator.RegionRegistry,
        Orchestrator.Migration.CircuitBreaker,
        Orchestrator.ChaosEngine,
        Orchestrator.Manager,
        Orchestrator.MachineManager,
        Orchestrator.MachineActor.Supervisor,
        {Orchestrator.ResourceManager, Application.get_env(:orchestrator, :resource_manager, [])},
        Orchestrator.ResourceQueue,
        Orchestrator.ResourceCoordinator,
        {Orchestrator.Replication.PartitionDetector, cluster_size: cluster_size()},
        {Orchestrator.Replication.StateSync,
         source_region: region_id(), target_regions: peer_regions()},
        Orchestrator.Security.OIDCProvider,
        Orchestrator.Security.KillSwitch,
        {Orchestrator.Recovery.Reconciler, [interval_ms: Application.get_env(:orchestrator, :reconciler_interval, 60_000)]},
        Orchestrator.NatsListener,
        Orchestrator.Metrics.Collector,
        Orchestrator.Metrics.LatencyTracker,
        OrchestratorWeb.Endpoint
      ] ++ prometheus_metrics() ++ worker_children()

    opts = [strategy: :one_for_one, name: Orchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp prometheus_metrics do
    if Mix.env() == :test do
      []
    else
      [
        {TelemetryMetricsPrometheus,
         metrics: Orchestrator.Metrics.metrics(), port: telemetry_port(), path: "/metrics"}
      ]
    end
  end

  defp worker_children do
    if Mix.env() == :test do
      []
    else
      [Orchestrator.Reconciliation.Engine]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    OrchestratorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp telemetry_port, do: String.to_integer(System.get_env("TELEMETRY_PORT", "9569"))

  defp cluster_size do
    default = if Mix.env() in [:dev, :test], do: "1", else: "3"
    System.get_env("CLUSTER_SIZE", default) |> String.to_integer()
  end

  defp region_id do
    System.get_env("FLY_REGION", "local")
  end

  defp peer_regions do
    case System.get_env("PEER_REGIONS") do
      nil -> []
      regions -> String.split(regions, ",", trim: true)
    end
  end
end
