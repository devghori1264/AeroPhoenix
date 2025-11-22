defmodule Orchestrator.Events.Event do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{
          id: binary(),
          event_type: atom(),
          event_version: integer(),
          aggregate_id: binary(),
          aggregate_type: String.t(),
          aggregate_version: integer(),
          data: map(),
          metadata: map(),
          causation_id: binary() | nil,
          correlation_id: binary() | nil,
          vector_clock: map(),
          actor_id: binary() | nil,
          actor_type: String.t() | nil,
          occurred_at: DateTime.t(),
          recorded_at: DateTime.t(),
          tags: list(String.t())
        }
  schema "events" do
    field(:event_type, Ecto.Enum,
      values: [
        :machine_created,
        :machine_started,
        :machine_stopped,
        :machine_destroyed,
        :state_transition_started,
        :state_transition_completed,
        :state_transition_failed,
        :migration_initiated,
        :migration_completed,
        :migration_failed,
        :resource_allocated,
        :resource_deallocated,
        :resource_throttled,
        :config_updated,
        :health_check_failed,
        :health_check_passed,
        :debug_session_started,
        :debug_breakpoint_hit,
        :debug_snapshot_created,
        :cost_threshold_exceeded,
        :scale_up_triggered,
        :scale_down_triggered,
        :feature_enabled,
        :feature_disabled,
        :system_error,
        :system_metric_recorded
      ]
    )

    field(:event_version, :integer, default: 1)
    field(:aggregate_id, :binary_id)
    field(:aggregate_type, :string)
    field(:aggregate_version, :integer)
    field(:data, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:causation_id, :binary_id)
    field(:correlation_id, :binary_id)
    field(:vector_clock, :map, default: %{})
    field(:actor_id, :binary_id)
    field(:actor_type, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:recorded_at, :utc_datetime_usec)
    field(:tags, {:array, :string}, default: [])
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :event_type,
      :event_version,
      :aggregate_id,
      :aggregate_type,
      :aggregate_version,
      :data,
      :metadata,
      :causation_id,
      :correlation_id,
      :vector_clock,
      :actor_id,
      :actor_type,
      :occurred_at,
      :tags
    ])
    |> validate_required([
      :id,
      :event_type,
      :aggregate_id,
      :aggregate_type,
      :aggregate_version,
      :occurred_at
    ])
    |> validate_number(:aggregate_version, greater_than: 0)
    |> validate_number(:event_version, greater_than: 0)
    |> validate_occurred_at_not_future()
    |> validate_json_structure()
    |> validate_uuid_format()
    |> unique_constraint([:aggregate_id, :aggregate_version],
      name: :events_aggregate_version_unique
    )
  end

  @spec for_aggregate(Ecto.Queryable.t(), binary()) :: Ecto.Query.t()
  def for_aggregate(query \\ __MODULE__, aggregate_id) do
    from(e in query,
      where: e.aggregate_id == ^aggregate_id,
      order_by: [asc: e.aggregate_version]
    )
  end

  @spec for_aggregate_range(Ecto.Queryable.t(), binary(), integer(), integer() | nil) ::
          Ecto.Query.t()
  def for_aggregate_range(query \\ __MODULE__, aggregate_id, from_version, to_version \\ nil) do
    query
    |> for_aggregate(aggregate_id)
    |> where([e], e.aggregate_version > ^from_version)
    |> maybe_filter_to_version(to_version)
  end

  @spec by_type_and_time(Ecto.Queryable.t(), atom(), DateTime.t(), DateTime.t()) ::
          Ecto.Query.t()
  def by_type_and_time(query \\ __MODULE__, event_type, start_time, end_time) do
    from(e in query,
      where: e.event_type == ^event_type,
      where: e.occurred_at >= ^start_time,
      where: e.occurred_at <= ^end_time,
      order_by: [desc: e.occurred_at]
    )
  end

  @spec by_correlation(Ecto.Queryable.t(), binary()) :: Ecto.Query.t()
  def by_correlation(query \\ __MODULE__, correlation_id) do
    from(e in query,
      where: e.correlation_id == ^correlation_id,
      order_by: [asc: e.occurred_at]
    )
  end

  @spec by_actor(Ecto.Queryable.t(), binary()) :: Ecto.Query.t()
  def by_actor(query \\ __MODULE__, actor_id) do
    from(e in query,
      where: e.actor_id == ^actor_id,
      order_by: [desc: e.occurred_at]
    )
  end

  @spec with_tags(Ecto.Queryable.t(), list(String.t())) :: Ecto.Query.t()
  def with_tags(query \\ __MODULE__, tags) when is_list(tags) do
    from(e in query,
      where: fragment("? && ?", e.tags, ^tags),
      order_by: [desc: e.occurred_at]
    )
  end

  @spec search(Ecto.Queryable.t(), String.t()) :: Ecto.Query.t()
  def search(query \\ __MODULE__, search_term) do
    from(e in query,
      where:
        fragment(
          "to_tsvector('english', ?::text) @@ plainto_tsquery('english', ?)",
          e.data,
          ^search_term
        ),
      order_by: [desc: e.occurred_at]
    )
  end

  @spec latest_version(binary()) :: integer()
  def latest_version(aggregate_id) do
    from(e in __MODULE__,
      where: e.aggregate_id == ^aggregate_id,
      select: max(e.aggregate_version)
    )
    |> Orchestrator.Repo.one()
    |> Kernel.||(0)
  end

  defp validate_occurred_at_not_future(changeset) do
    validate_change(changeset, :occurred_at, fn :occurred_at, occurred_at ->
      if DateTime.compare(occurred_at, DateTime.utc_now()) == :gt do
        [occurred_at: "cannot be in the future"]
      else
        []
      end
    end)
  end

  defp validate_json_structure(changeset) do
    changeset
    |> validate_change(:data, &validate_is_map/2)
    |> validate_change(:metadata, &validate_is_map/2)
    |> validate_change(:vector_clock, &validate_is_map/2)
  end

  defp validate_is_map(field, value) do
    if is_map(value) do
      []
    else
      [{field, "must be a map"}]
    end
  end

  defp validate_uuid_format(changeset) do
    changeset
    |> validate_uuid_field(:id)
    |> validate_uuid_field(:aggregate_id)
    |> validate_uuid_field(:causation_id, required: false)
    |> validate_uuid_field(:correlation_id, required: false)
    |> validate_uuid_field(:actor_id, required: false)
  end

  defp validate_uuid_field(changeset, field, opts \\ [required: true]) do
    if Keyword.get(opts, :required, true) || get_field(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        case Ecto.UUID.cast(value) do
          {:ok, _} -> []
          :error -> [{field, "invalid UUID format"}]
        end
      end)
    else
      changeset
    end
  end

  defp maybe_filter_to_version(query, nil), do: query

  defp maybe_filter_to_version(query, to_version) do
    where(query, [e], e.aggregate_version <= ^to_version)
  end
end
