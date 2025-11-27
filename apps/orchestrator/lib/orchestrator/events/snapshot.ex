defmodule Orchestrator.Events.Snapshot do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo

  @type t :: %__MODULE__{
          id: binary(),
          aggregate_id: binary(),
          aggregate_type: String.t(),
          aggregate_version: integer(),
          state: map(),
          metadata: map(),
          checksum: String.t(),
          compressed: boolean(),
          created_at: DateTime.t(),
          inserted_at: DateTime.t()
        }
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_snapshots" do
    field(:aggregate_id, :binary_id)
    field(:aggregate_type, :string)
    field(:aggregate_version, :integer)
    field(:state, :map)
    field(:metadata, :map, default: %{})
    field(:checksum, :string)
    field(:compressed, :boolean, default: false)
    field(:created_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :aggregate_id,
      :aggregate_type,
      :aggregate_version,
      :state,
      :metadata,
      :checksum,
      :compressed,
      :created_at
    ])
    |> validate_required([
      :aggregate_id,
      :aggregate_type,
      :aggregate_version,
      :state
    ])
    |> validate_number(:aggregate_version, greater_than: 0)
    |> put_created_at()
    |> put_checksum()
  end

  @spec latest_for_aggregate(binary(), integer() | nil) :: t() | nil
  def latest_for_aggregate(aggregate_id, before_version \\ nil) do
    query =
      from(s in __MODULE__,
        where: s.aggregate_id == ^aggregate_id,
        order_by: [desc: s.aggregate_version],
        limit: 1
      )

    query =
      if before_version do
        where(query, [s], s.aggregate_version <= ^before_version)
      else
        query
      end

    Repo.one(query)
  end

  @spec create_snapshot(binary(), map(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create_snapshot(aggregate_id, state, opts \\ []) do
    aggregate_version = Keyword.fetch!(opts, :aggregate_version)
    aggregate_type = Keyword.get(opts, :aggregate_type, "Machine")
    compress = Keyword.get(opts, :compress, true)
    metadata = Keyword.get(opts, :metadata, %{})

    attrs = %{
      aggregate_id: aggregate_id,
      aggregate_type: aggregate_type,
      aggregate_version: aggregate_version,
      state: state,
      metadata: metadata,
      compressed: compress
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  defp put_created_at(changeset) do
    if get_field(changeset, :created_at) do
      changeset
    else
      put_change(changeset, :created_at, DateTime.utc_now())
    end
  end

  defp put_checksum(changeset) do
    if state = get_change(changeset, :state) do
      checksum = :crypto.hash(:sha256, Jason.encode!(state)) |> Base.encode16(case: :lower)
      put_change(changeset, :checksum, checksum)
    else
      changeset
    end
  end
end
