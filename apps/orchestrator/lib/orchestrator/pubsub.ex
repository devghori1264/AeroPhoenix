defmodule Orchestrator.PubSub do
  require Logger

  def publish_machine_update(%Orchestrator.Machine{} = m) do
    payload = %{
      "id" => m.id,
      "name" => m.name,
      "region" => m.region,
      "status" => m.status,
      "cpu" => m.cpu,
      "memory_mb" => m.memory_mb,
      "latency_ms" => m.latency_ms,
      "updated_at" => DateTime.to_iso8601(m.updated_at || DateTime.utc_now())
    }

    case :gnat.start_link(%{host: Application.get_env(:orchestrator, :nats)[:url]}) do
      {:ok, conn} ->
        :gnat.pub(conn, "machines.events", Jason.encode!(payload))
      {:error, _} -> Logger.debug("NATS unavailable — skipping publish")
    end

    :ok
  end
end
