defmodule OrchestratorWeb.MachineController do
  use OrchestratorWeb, :controller
  require Logger
  alias Orchestrator.{Manager, Repo, Machines.Machine}

  def index(conn, _params) do
    json(conn, Manager.list_machines())
  end

  def create(
        conn,
        %{"name" => name, "region" => region, "cpu_size" => cpu_size, "memory_mb" => memory_mb} =
          params
      )
      when is_binary(name) and is_binary(region) and is_binary(cpu_size) do
    memory_int =
      case memory_mb do
        mb when is_integer(mb) -> mb
        mb when is_binary(mb) -> String.to_integer(mb)
        _ -> 512
      end

    Logger.info(
      "Creating machine: name=#{name}, region=#{region}, cpu=#{cpu_size}, memory=#{memory_int}MB, all_params=#{inspect(params)}"
    )

    {:ok, machine} = Manager.create_machine(name, region, cpu_size, memory_int)
    json(conn, machine)
  end

  def create(conn, %{"name" => name, "region" => region} = params)
      when is_binary(name) and is_binary(region) do
    Logger.info(
      "Creating machine (legacy params): name=#{name}, region=#{region}, all_params=#{inspect(params)}"
    )

    {:ok, machine} = Manager.create_machine(name, region, "dedicated-cpu-1x", 512)
    json(conn, machine)
  end

  def create(conn, params) do
    Logger.error("create/2 called with unmatched params: #{inspect(params)}")

    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "Invalid parameters", received: params}})
  end

  def show(conn, %{"id" => id}) do
    case Repo.get(Machine, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Not Found"}})

      machine ->
        json(conn, machine)
    end
  end

  def perform_action(conn, params) do
    id = params["id"]
    action_param = params["action"]

    Logger.info(
      "Received action request: id=#{id}, action=#{action_param}, params=#{inspect(params)}"
    )

    case Repo.get(Machine, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Not Found"}})

      machine ->
        Task.start(fn ->
          Logger.info("Performing action #{action_param} on machine #{id} (#{machine.name})")

          new_status =
            case action_param do
              "stop" -> "stopped"
              "start" -> "running"
              "restart" -> "running"
              _ -> machine.status
            end

          changeset = Ecto.Changeset.change(machine, status: new_status)

          case Repo.update(changeset) do
            {:ok, updated} ->
              Logger.info("Machine #{id} status updated to #{new_status}")

              Phoenix.PubSub.broadcast(
                Orchestrator.PubSub,
                "machines:#{id}",
                {:machine_updated, updated}
              )

            {:error, reason} ->
              Logger.error("Failed to update machine #{id}: #{inspect(reason)}")
          end
        end)

        conn
        |> put_status(:accepted)
        |> json(%{status: "accepted", action: action_param, machine_id: id})
    end
  end
end
