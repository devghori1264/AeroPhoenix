defmodule Orchestrator.PubSub do
  require Logger

  def publish_machine_update(%Orchestrator.Machines.Machine{} = m) do
    payload = %{
      "id" => m.id,
      "name" => m.name,
      "region" => m.region,
      "status" => m.status,
      "cpu" => m.cpu_count,
      "memory_mb" => m.memory_mb,
      "updated_at" => DateTime.to_iso8601(m.updated_at || DateTime.utc_now())
    }

    Task.start(fn ->
      try do
        nats_url = Application.get_env(:orchestrator, :nats)[:url] || "nats://localhost:4222"
        uri = URI.parse(nats_url)
        opts = %{host: uri.host, port: uri.port || 4222}

        case Gnat.start_link(opts) do
          {:ok, conn} ->
            Gnat.pub(conn, "machines.events", Jason.encode!(payload))
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
