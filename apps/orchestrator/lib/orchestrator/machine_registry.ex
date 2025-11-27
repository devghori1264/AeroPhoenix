defmodule Orchestrator.MachineRegistry do
  def get_pid(machine_id) do
    case Registry.lookup(Orchestrator.MachineActorRegistry, machine_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  def get_root_path(machine_id) do
    case get_pid(machine_id) do
      {:ok, _pid} ->
        root =
          Path.join([
            Application.get_env(:orchestrator, :data_dir, "/tmp/orchestrator/data"),
            "machines",
            machine_id,
            "rootfs"
          ])

        {:ok, root}

      {:error, :not_found} = error ->
        error
    end
  end

  def list_machine_ids do
    Registry.select(Orchestrator.MachineActorRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def running?(machine_id) do
    case get_pid(machine_id) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
    end
  end

  def put_metadata(machine_id, key, value) do
    table_name = :machine_registry_metadata

    unless :ets.whereis(table_name) != :undefined do
      :ets.new(table_name, [:set, :public, :named_table])
    end

    :ets.insert(table_name, {{machine_id, key}, value})
    :ok
  end

  def get_metadata(machine_id, key) do
    table_name = :machine_registry_metadata

    case :ets.whereis(table_name) do
      :undefined ->
        {:error, :not_found}

      _table ->
        case :ets.lookup(table_name, {machine_id, key}) do
          [{{^machine_id, ^key}, value}] -> {:ok, value}
          [] -> {:error, :not_found}
        end
    end
  end
end
