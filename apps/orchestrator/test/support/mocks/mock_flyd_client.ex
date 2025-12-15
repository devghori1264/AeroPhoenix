defmodule Orchestrator.MockFlydClient do
  require Logger

  def create_machine(_config), do: {:ok, %{"id" => "mock-id", "status" => "created"}}

  def migrate_machine("error", _target, _opts), do: {:error, :simulated_error}

  def migrate_machine(_id, _target, _opts) do
    Logger.info("MockFlydClient.migrate_machine called")
    {:ok, %{"migration_id" => "mig_#{Ecto.UUID.generate()}", "estimated_duration_ms" => 100}}
  end

  def stop_machine("error"), do: {:error, :simulated_error}
  def stop_machine(id), do: {:ok, %{"id" => id, "status" => "stopped"}}

  def start_machine("error"), do: {:error, :simulated_error}
  def start_machine(id), do: {:ok, %{"id" => id, "status" => "started"}}

  def suspend_machine("error"), do: {:error, :simulated_error}
  def suspend_machine(_id), do: {:ok, %{}}

  def get_machine("error"), do: {:error, :simulated_error}
  def get_machine(_id), do: {:ok, %{}}

  def stream_migration_progress(_id), do: Stream.map(1..5, & &1)

  def stream_migration_progress(_id, callback) do
    Enum.each(1..5, callback)
    {:ok, :completed}
  end

  def destroy_machine("error"), do: {:error, :simulated_error}
  def destroy_machine(_id), do: {:ok, %{}}
  def destroy_machine(_region, _id), do: {:ok, %{}}

  def get_machine_health(_region, "not_implemented"), do: {:error, :not_implemented}
  def get_machine_health(_region, _id), do: {:ok, %{status: "healthy"}}
  def get_region_capacity(_region), do: {:ok, %{available_slots: 10}}
  def ping_region(_source, _target), do: {:ok, 50}
  def get_machine_size(_region, _id), do: {:ok, 1024 * 1024 * 1024}
  def pause_machine(_region, _id), do: :ok
  def resume_machine(_region, _id), do: :ok
  def get_machine_memory_dump(_region, _id), do: {:ok, %{"heap" => "data", "stack" => "data"}}
  def create_fs_snapshot(_region, _id), do: {:ok, "snap_123"}
  def get_machine_network_state(_region, _id), do: {:ok, %{"connections" => []}}
  def get_machine_app_state(_region, _id), do: {:ok, %{}}
  def restore_fs_snapshot(_region, _id, _snap_id), do: :ok
  def restore_machine_memory(_region, _id, _dump), do: :ok
  def restore_machine_network_state(_region, _id, _state), do: :ok
  def restore_machine_app_state(_region, _id, _state), do: :ok
  def get_machine_pages(_region, pages), do: {:ok, String.duplicate("a", length(pages) * 100)}
  def write_machine_pages(_region, _data, _checksum, _opts), do: :ok
  def verify_pages_checksum(_region, _id, _checksum), do: :ok
  def get_dirty_pages_since_checkpoint(_region, _id, _ckpt), do: {:ok, Enum.to_list(1..50)}
  def get_critical_pages(_region, _ckpt), do: {:ok, []}
  def drain_connections(_region, _id, timeout) when timeout < 100, do: {:error, :timeout}
  def drain_connections(_region, "not_implemented", _timeout), do: {:error, :not_implemented}
  def drain_connections(_region, _id, _timeout), do: :ok
  def release_ip(_region, "not_implemented"), do: {:error, :not_implemented}
  def release_ip(_region, _id), do: {:ok, "127.0.0.1"}
  def assign_ip(_region, _id, _ip), do: :ok
  def update_dns_record("not_implemented", _region, _ttl), do: {:error, :not_implemented}
  def update_dns_record(_id, _region, _ttl), do: {:ok, "new.endpoint"}
  def start_traffic_capture(_region, "not_implemented"), do: {:error, :not_implemented}
  def start_traffic_capture(_region, _id), do: {:ok, "buf_123"}
  def replay_captured_traffic(_buf, "not_implemented"), do: {:error, :not_implemented}
  def replay_captured_traffic(_buf, _endpoint), do: {:ok, %{}}
  def get_connection_stats(_region, "not_implemented"), do: {:error, :not_implemented}
  def get_connection_stats(_region, _id), do: {:ok, %{}}
  def get_machine_state(id, opts \\ [])

  def get_machine_state("error-" <> _rest, _opts) do
    {:error, :simulated_error}
  end

  def get_machine_state(_id, _opts) do
    {:ok,
     %{
       status: "started",
       config: %{image: "nginx", size: "s-1vcpu-1gb", region: "us-east-1"}
     }}
  end
end
