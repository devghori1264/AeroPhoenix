defmodule OrchestratorWeb.Router do
  use OrchestratorWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {OrchestratorWeb.LayoutView, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/api/v1", OrchestratorWeb do
    pipe_through(:api)
    get("/ping", HealthController, :ping)
    get("/topology", TopologyController, :index)
    get("/machines", MachineController, :index)
    post("/machines", MachineController, :create)
    get("/machines/:id", MachineController, :show)
    post("/machines/:id/action", MachineController, :perform_action)
    get("/chaos/active", ChaosController, :list_active)
    post("/chaos/start", ChaosController, :start)
    post("/chaos/stop/:id", ChaosController, :stop)

    # FSM Introspection and Visualization
    get("/fsm/graph", FSMController, :get_graph)
    get("/fsm/stats", FSMController, :get_stats)
    get("/fsm/:machine_id/state", FSMController, :get_state)
    get("/fsm/:machine_id/history", FSMController, :get_history)
    get("/fsm/:machine_id/timeline", FSMController, :get_timeline)
    post("/fsm/:machine_id/health_check", FSMController, :trigger_health_check)

    # Debug / Inspection APIs
    get("/debug/metrics/:id", DebugController, :metrics)
    get("/debug/threads/:id", DebugController, :threads)
    get("/debug/network/:id", DebugController, :network)
    get("/debug/fds/:id", DebugController, :file_descriptors)

    # Event Sourcing / Replay APIs
    get("/events/aggregates", EventController, :list_aggregates)
    get("/events/search", EventController, :search)
    get("/events/correlation/:correlation_id", EventController, :trace)
    get("/events/:aggregate_id", EventController, :show)
    post("/events/:aggregate_id/rebuild", EventController, :rebuild)
    get("/events/:aggregate_id/diff", EventController, :diff)

    # Placement Optimization APIs
    post("/placement/optimize", PlacementController, :optimize)
    get("/placement/evaluate/:machine_id", PlacementController, :evaluate)
    get("/placement/consolidations", PlacementController, :consolidations)
    get("/placement/rightsizing", PlacementController, :rightsizing)
    get("/placement/cost", PlacementController, :cost_analysis)
    post("/placement/budget", PlacementController, :enforce_budget)

    # Optimization Execution APIs (NEW - Step 8)
    post("/optimizations/cost", OptimizationController, :optimize_cost)
    post("/optimizations/latency", OptimizationController, :optimize_latency)
    post("/optimizations/combined", OptimizationController, :optimize_combined)
    get("/optimizations/history", OptimizationController, :get_history)
    post("/optimizations/execute", OptimizationController, :execute_placement)
    post("/optimizations/rollback/:execution_id", OptimizationController, :rollback_execution)

    # Feature Flag APIs
    resources "/flags", FlagController, except: [:edit, :new] do
      post("/enable", FlagController, :enable)
      post("/disable", FlagController, :disable)
      post("/evaluate", FlagController, :evaluate)
      get("/statistics", FlagController, :statistics)
    end

    post("/flags/evaluate_batch", FlagController, :evaluate_batch)

    # Experiment APIs
    resources "/experiments", ExperimentController, except: [:edit, :new, :update] do
      post("/start", ExperimentController, :start)
      post("/pause", ExperimentController, :pause)
      post("/complete", ExperimentController, :complete)
      get("/analysis", ExperimentController, :analysis)
      get("/early_stopping", ExperimentController, :check_early_stopping)
      post("/select_winner", ExperimentController, :select_winner)
    end

    # Override APIs
    resources("/overrides", OverrideController, only: [:create, :show, :delete])
  end

  scope "/", OrchestratorWeb do
    pipe_through(:api)
    get("/health", HealthController, :health)
  end

  scope "/planner", OrchestratorWeb do
    pipe_through(:api)
    get("/recommend", PlannerController, :recommend)
  end
end
