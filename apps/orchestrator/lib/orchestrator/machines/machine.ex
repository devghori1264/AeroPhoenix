defmodule Orchestrator.Machines.Machine do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Orchestrator.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :region,
             :status,
             :machine_type,
             :cpu_count,
             :memory_mb,
             :service,
             :config,
             :tags,
             :version,
             :metadata,
             :last_seen_at,
             :inserted_at,
             :updated_at
           ]}

  schema "machines" do
    field(:name, :string)
    field(:region, :string)

    field(:status, :string)
    field(:machine_type, :string)
    field(:cpu_count, :integer, default: 1)
    field(:memory_mb, :integer, default: 256)
    field(:service, :string)
    field(:config, :map, default: %{})
    field(:tags, :map, default: %{})
    field(:version, :integer, default: 1)
    field(:metadata, :map, default: %{})
    field(:last_seen_at, :utc_datetime_usec)
    timestamps()
  end

  @required_fields ~w(name region status machine_type)a
  @optional_fields ~w(id cpu_count memory_mb service config tags version metadata last_seen_at)a
  def changeset(machine, attrs) do
    machine
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, [
      "created",
      "stopped",
      "starting",
      "running",
      "stopping",
      "migrating",
      "destroyed",
      "healthy",
      "unhealthy",
      "unknown",
      "provisioning",
      "terminating",
      "pending",
      "suspended",
      "error"
    ])
    |> validate_number(:cpu_count, greater_than: 0)
    |> validate_number(:memory_mb, greater_than: 0)
    |> unique_constraint(:name)
  end

  def list_by_service(repo, service_name, opts \\ []) do
    query =
      from(m in __MODULE__,
        where: m.service == ^service_name,
        order_by: [desc: m.inserted_at]
      )

    query = apply_filters(query, opts)
    repo.all(query)
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update(machine, attrs) do
    machine
    |> changeset(attrs)
    |> Repo.update()
  end

  def get(id) do
    case Repo.get(__MODULE__, id) do
      nil -> {:error, :not_found}
      machine -> {:ok, machine}
    end
  end

  def destroy(machine) do
    __MODULE__.update(machine, %{status: "destroyed"})
  end

  def stop(machine_id) do
    with {:ok, machine} <- get(machine_id) do
      __MODULE__.update(machine, %{status: "stopped"})
    end
  end

  def update_config(machine_id, new_config) do
    with {:ok, machine} <- get(machine_id) do
      __MODULE__.update(machine, %{config: new_config})
    end
  end

  def update_tags(machine_id, new_tags) do
    with {:ok, machine} <- get(machine_id) do
      __MODULE__.update(machine, %{tags: new_tags})
    end
  end

  def active_machines do
    from(m in __MODULE__,
      where: m.status != "destroyed",
      order_by: [desc: m.inserted_at]
    )
  end

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:region, region}, q ->
        from(m in q, where: m.region == ^region)

      {:status, status}, q ->
        from(m in q, where: m.status == ^status)

      _other, q ->
        q
    end)
  end
end
