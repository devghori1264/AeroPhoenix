defmodule Orchestrator.Cost.ResourceUsage do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  require Logger

  @type t :: %__MODULE__{
          id: binary(),
          machine_id: binary(),
          region: String.t(),
          measured_at: DateTime.t(),
          metrics: map(),
          cpu_percent: float() | nil,
          memory_mb: float() | nil,
          storage_gb: float() | nil,
          network_ingress_gb: float() | nil,
          network_egress_gb: float() | nil,
          iops_read: integer() | nil,
          iops_write: integer() | nil,
          request_count: integer() | nil,
          cpu_idle_percent: float() | nil,
          memory_free_mb: float() | nil,
          is_idle: boolean(),
          tags: list(String.t()),
          cost_center: String.t() | nil,
          environment: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t()
        }
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "resource_usage" do
    field(:machine_id, :binary_id)
    field(:region, :string)
    field(:measured_at, :utc_datetime_usec)
    field(:metrics, :map)
    field(:cpu_percent, :float)
    field(:memory_mb, :float)
    field(:storage_gb, :float)
    field(:network_ingress_gb, :float)
    field(:network_egress_gb, :float)
    field(:iops_read, :integer)
    field(:iops_write, :integer)
    field(:request_count, :integer)
    field(:cpu_idle_percent, :float)
    field(:memory_free_mb, :float)
    field(:is_idle, :boolean, default: false)
    field(:tags, {:array, :string}, default: [])
    field(:cost_center, :string)
    field(:environment, :string)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(usage, attrs) do
    usage
    |> cast(attrs, [
      :machine_id,
      :region,
      :measured_at,
      :metrics,
      :cpu_percent,
      :memory_mb,
      :storage_gb,
      :network_ingress_gb,
      :network_egress_gb,
      :iops_read,
      :iops_write,
      :request_count,
      :cpu_idle_percent,
      :memory_free_mb,
      :is_idle,
      :tags,
      :cost_center,
      :environment,
      :metadata
    ])
    |> validate_required([:machine_id, :region, :measured_at, :metrics])
    |> validate_number(:cpu_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:memory_mb, greater_than_or_equal_to: 0)
    |> validate_number(:storage_gb, greater_than_or_equal_to: 0)
    |> validate_number(:network_ingress_gb, greater_than_or_equal_to: 0)
    |> validate_number(:network_egress_gb, greater_than_or_equal_to: 0)
    |> validate_number(:iops_read, greater_than_or_equal_to: 0)
    |> validate_number(:iops_write, greater_than_or_equal_to: 0)
    |> put_measured_at()
  end

  @spec record_usage(binary(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record_usage(machine_id, metrics) do
    attrs =
      metrics
      |> Map.put(:machine_id, machine_id)
      |> Map.put(:metrics, metrics)

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @spec recent_for_machine(binary(), keyword()) :: list(t())
  def recent_for_machine(machine_id, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    limit = Keyword.get(opts, :limit, 1000)

    from(u in __MODULE__,
      where: u.machine_id == ^machine_id,
      where: u.measured_at > ago(^hours, "hour"),
      order_by: [desc: u.measured_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @spec idle_machines(keyword()) :: list(t())
  def idle_machines(opts \\ []) do
    cpu_threshold = Keyword.get(opts, :cpu_threshold, 5.0)
    memory_threshold = Keyword.get(opts, :memory_threshold, 20.0)
    hours = Keyword.get(opts, :hours, 24)

    Logger.debug("Finding idle machines (CPU < #{cpu_threshold}%, Memory < #{memory_threshold}%)")

    from(u in __MODULE__,
      where: u.measured_at > ago(^hours, "hour"),
      where: u.is_idle == true,
      where: u.cpu_percent < ^cpu_threshold,
      distinct: u.machine_id,
      order_by: [desc: u.measured_at]
    )
    |> Repo.all()
  end

  defp put_measured_at(changeset) do
    if get_field(changeset, :measured_at) do
      changeset
    else
      put_change(changeset, :measured_at, DateTime.utc_now())
    end
  end
end
