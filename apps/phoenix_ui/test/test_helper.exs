# Start Orchestrator.PubSub for tests
{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: Orchestrator.PubSub}],
    strategy: :one_for_one
  )

ExUnit.start()
