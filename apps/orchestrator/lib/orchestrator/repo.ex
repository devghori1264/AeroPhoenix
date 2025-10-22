defmodule Orchestrator.Repo do
  use Ecto.Repo,
    otp_app: :orchestrator,
    adapter: Ecto.Adapters.Postgres
end
