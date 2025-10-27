defmodule Orchestrator.MachineManager do
  use Supervisor
  require Logger

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_), do: Supervisor.init([], strategy: :one_for_one)

  def ensure_started(id, attrs \\ %{}) do
    case Registry.lookup(Orchestrator.FSMRegistry, id) do
      [{pid, _}] -> {:ok, pid}
      [] ->
        child = %{
          id: Orchestrator.MachineFSM,
          start: {Orchestrator.MachineFSM, :start_link, [%{id: id} |> Map.merge(attrs)]},
          restart: :transient
        }
        Supervisor.start_child(__MODULE__, child)
    end
  end
end
