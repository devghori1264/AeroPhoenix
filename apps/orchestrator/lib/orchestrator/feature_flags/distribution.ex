defmodule Orchestrator.FeatureFlags.Distribution do
  require Logger
  alias Phoenix.PubSub
  alias Orchestrator.FeatureFlags.Engine
  @pubsub Orchestrator.PubSub
  @flag_updated_topic "flags:updated"
  @flag_deleted_topic "flags:deleted"
  @experiment_updated_topic "experiments:updated"
  def broadcast_flag_update(flag) do
    message = %{
      event: "flag_updated",
      flag_key: flag.key,
      flag_id: flag.id,
      version: flag.version,
      timestamp: DateTime.utc_now()
    }

    PubSub.broadcast(@pubsub, @flag_updated_topic, message)
    PubSub.broadcast(@pubsub, "flag:#{flag.key}", message)
    Logger.debug("Broadcasted flag update: #{flag.key}")
    :ok
  end

  def broadcast_flag_delete(flag_key) do
    message = %{
      event: "flag_deleted",
      flag_key: flag_key,
      timestamp: DateTime.utc_now()
    }

    PubSub.broadcast(@pubsub, @flag_deleted_topic, message)
    PubSub.broadcast(@pubsub, "flag:#{flag_key}", message)
    Logger.debug("Broadcasted flag deletion: #{flag_key}")
    :ok
  end

  def broadcast_experiment_update(experiment) do
    message = %{
      event: "experiment_updated",
      experiment_id: experiment.id,
      experiment_key: experiment.key,
      status: experiment.status,
      timestamp: DateTime.utc_now()
    }

    PubSub.broadcast(@pubsub, @experiment_updated_topic, message)
    PubSub.broadcast(@pubsub, "experiment:#{experiment.key}", message)
    Logger.debug("Broadcasted experiment update: #{experiment.key}")
    :ok
  end

  def subscribe_to_flag_updates do
    PubSub.subscribe(@pubsub, @flag_updated_topic)
    PubSub.subscribe(@pubsub, @flag_deleted_topic)
  end

  def subscribe_to_flag(flag_key) do
    PubSub.subscribe(@pubsub, "flag:#{flag_key}")
  end

  def subscribe_to_experiment_updates do
    PubSub.subscribe(@pubsub, @experiment_updated_topic)
  end

  def subscribe_to_experiment(experiment_key) do
    PubSub.subscribe(@pubsub, "experiment:#{experiment_key}")
  end

  def invalidate_flag_cache(flag_key) do
    Engine.invalidate_cache(flag_key)
    Logger.debug("Invalidated cache for flag: #{flag_key}")
    :ok
  end

  def invalidate_all_caches do
    Engine.clear_cache()
    Logger.info("Invalidated all flag caches")
    :ok
  end

  def warm_cache(flag_keys) when is_list(flag_keys) do
    Logger.info("Warming cache for #{length(flag_keys)} flags")

    Enum.each(flag_keys, fn key ->
      Engine.load_flag(key)
    end)

    :ok
  end

  def auto_warm_cache(limit \\ 100) do
    query = """
    SELECT flag_key, COUNT(*) as eval_count
    FROM flag_evaluations
    WHERE evaluated_at >= NOW() - INTERVAL '1 hour'
    GROUP BY flag_key
    ORDER BY eval_count DESC
    LIMIT $1
    """

    case Ecto.Adapters.SQL.query(Orchestrator.Repo, query, [limit]) do
      {:ok, %{rows: rows}} ->
        flag_keys = Enum.map(rows, fn [key, _count] -> key end)
        warm_cache(flag_keys)

      {:error, error} ->
        Logger.error("Failed to auto-warm cache: #{inspect(error)}")
        {:error, error}
    end
  end
end
