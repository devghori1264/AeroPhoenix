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

    Task.start(fn ->
      try do
        nats_url = Application.get_env(:orchestrator, :nats)[:url] || "nats://localhost:4222"

        case :gnat.start_link(%{host: nats_url}) do
          {:ok, conn} ->
            :gnat.pub(conn, "machines.events", Jason.encode!(payload))
            GenServer.stop(conn)

          {:error, reason} ->
            Logger.debug("NATS unavailable — skipping publish: #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.debug("NATS not available: #{inspect(e)}")
      end
    end)

    :ok
  end
end
