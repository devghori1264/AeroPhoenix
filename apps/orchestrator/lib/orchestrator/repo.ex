defmodule Orchestrator.Repo do
  use Ecto.Repo,
    otp_app: :orchestrator,
    adapter: Ecto.Adapters.SQLite3
end
