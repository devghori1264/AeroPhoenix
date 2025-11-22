defmodule Orchestrator.FeatureFlags.Jobs.CacheWarmerJob do
  use Oban.Worker,
    queue: :cache,
    max_attempts: 2,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  require Logger
  alias Orchestrator.FeatureFlags.Distribution
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("Running cache warmer job")

    case Distribution.auto_warm_cache(100) do
      :ok ->
        Logger.debug("Successfully warmed cache")
        :ok

      {:error, reason} ->
        Logger.error("Cache warmer failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def schedule do
    %{}
    |> __MODULE__.new(schedule_in: 60)
    |> Oban.insert()
  end
end
