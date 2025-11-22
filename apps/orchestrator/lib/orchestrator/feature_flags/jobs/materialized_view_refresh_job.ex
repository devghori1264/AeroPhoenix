defmodule Orchestrator.FeatureFlags.Jobs.MaterializedViewRefreshJob do
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  require Logger
  alias Orchestrator.Repo
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Refreshing flag statistics materialized view")
    query = "REFRESH MATERIALIZED VIEW CONCURRENTLY flag_statistics"

    case Ecto.Adapters.SQL.query(Repo, query, []) do
      {:ok, _result} ->
        Logger.info("Successfully refreshed flag statistics materialized view")
        :ok

      {:error, reason} ->
        Logger.error("Failed to refresh materialized view: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def schedule do
    %{}
    |> __MODULE__.new(schedule_in: 3600)
    |> Oban.insert()
  end
end
