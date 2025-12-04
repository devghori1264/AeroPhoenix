unless Process.whereis(Orchestrator.PubSub) do
  Phoenix.PubSub.Supervisor.start_link(name: Orchestrator.PubSub, adapter: Phoenix.PubSub.PG2)
end

unless Process.whereis(Orchestrator.MachineActorRegistry) do
  Registry.start_link(keys: :unique, name: Orchestrator.MachineActorRegistry)
end

unless Process.whereis(Orchestrator.FSMRegistry) do
  Registry.start_link(keys: :unique, name: Orchestrator.FSMRegistry)
end

unless Process.whereis(Orchestrator.Registry) do
  Registry.start_link(keys: :unique, name: Orchestrator.Registry)
end

unless Process.whereis(Orchestrator.LiveMigrationRegistry) do
  Registry.start_link(keys: :unique, name: Orchestrator.LiveMigrationRegistry)
end

unless Process.whereis(Orchestrator.Finch) do
  Finch.start_link(name: Orchestrator.Finch)
end

File.rm_rf!("tmp/test_machines")
File.mkdir_p!("tmp/test_machines")
Application.put_env(:orchestrator, :storage_path, "tmp/test_machines/")

is_ci = System.get_env("CI") == "true"
cores = System.schedulers_online()

max_cases = if is_ci do
  min(cores * 2, 4) 
else
  8 
end

IO.puts """
=============================================================
 Test Runner Configuration
   Environment: #{if is_ci, do: "CI (GitHub)", else: "Local (M1/Dev)"}
   Available Cores: #{cores}
   Concurrency Limit: #{max_cases} workers
=============================================================
"""

ExUnit.start(
  max_cases: max_cases,
  timeout: 120_000,
  assert_receive_timeout: 1_000 
)

Application.put_env(:orchestrator, Orchestrator.Repo, 
  pool_size: max_cases + 5, 
  ownership_timeout: 120_000
)

case Orchestrator.Repo.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
  {:error, reason} -> raise "Failed to start Repo: #{inspect(reason)}"
end

Ecto.Adapters.SQL.Sandbox.mode(Orchestrator.Repo, :manual)
