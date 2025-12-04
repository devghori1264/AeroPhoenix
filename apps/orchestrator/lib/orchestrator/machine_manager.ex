defmodule Orchestrator.MachineManager do
  use DynamicSupervisor
  require Logger

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def ensure_started(id, attrs \\ %{}) do
    case Registry.lookup(Orchestrator.FSMRegistry, id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_spec = %{
          id: Orchestrator.MachineFSM,
          start: {Orchestrator.MachineFSM, :start_link, [%{id: id} |> Map.merge(attrs)]},
          restart: :transient
        }

        DynamicSupervisor.start_child(__MODULE__, child_spec)
    end
  end
end
