defmodule Orchestrator.Events.Reader do
  require Logger
  import Ecto.Query
  alias Orchestrator.Events.Event
  alias Orchestrator.Events.Snapshot
  alias Orchestrator.Repo

  @type read_opts :: [
          from_version: integer(),
          to_version: integer() | nil,
          limit: integer(),
          use_snapshot: boolean()
        ]
  @type filter_opts :: [
          aggregate_id: binary() | nil,
          aggregate_type: String.t() | nil,
          event_types: list(atom()),
          start_time: DateTime.t() | nil,
          end_time: DateTime.t() | nil,
          correlation_id: binary() | nil,
          actor_id: binary() | nil,
          tags: list(String.t())
        ]
  @type stream_result :: Enumerable.t()
  @type read_result :: {:ok, list(Event.t())} | {:error, term()}
  @type snapshot_result :: {:ok, {Snapshot.t() | nil, list(Event.t())}} | {:error, term()}
  @default_limit 1000
  @default_batch_size 100
  @spec read_stream(binary(), read_opts()) :: read_result()
  def read_stream(aggregate_id, opts \\ []) do
    from_version = Keyword.get(opts, :from_version, 0)
    to_version = Keyword.get(opts, :to_version)
    limit = Keyword.get(opts, :limit, @default_limit)

    query =
      Event
      |> Event.for_aggregate_range(aggregate_id, from_version, to_version)
      |> limit(^limit)

    {:ok, Repo.all(query)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec read_from_snapshot(binary(), keyword()) :: snapshot_result()
  def read_from_snapshot(aggregate_id, opts \\ []) do
    to_version = Keyword.get(opts, :to_version)
    snapshot = Snapshot.latest_for_aggregate(aggregate_id, to_version)

    from_version =
      if snapshot do
        snapshot.aggregate_version
      else
        0
      end

    case read_stream(aggregate_id, Keyword.put(opts, :from_version, from_version)) do
      {:ok, events} -> {:ok, {snapshot, events}}
      error -> error
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec stream_events(filter_opts()) :: stream_result()
  def stream_events(opts \\ []) do
    query = build_filter_query(opts)
    Repo.stream(query, max_rows: @default_batch_size)
  end

  @spec by_correlation(binary(), keyword()) :: read_result()
  def by_correlation(correlation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    events =
      Event
      |> Event.by_correlation(correlation_id)
      |> limit(^limit)
      |> Repo.all()

    {:ok, events}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec by_actor(binary(), keyword()) :: read_result()
  def by_actor(actor_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    events =
      Event
      |> Event.by_actor(actor_id)
      |> limit(^limit)
      |> Repo.all()

    {:ok, events}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec search(String.t(), keyword()) :: read_result()
  def search(query_string, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    events =
      Event
      |> Event.search(query_string)
      |> limit(^limit)
      |> Repo.all()

    {:ok, events}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec by_tags(list(String.t()), keyword()) :: read_result()
  def by_tags(tags, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    events =
      Event
      |> Event.with_tags(tags)
      |> limit(^limit)
      |> Repo.all()

    {:ok, events}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec by_type_and_time(atom(), DateTime.t(), DateTime.t(), keyword()) :: read_result()
  def by_type_and_time(event_type, start_time, end_time, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    events =
      Event
      |> Event.by_type_and_time(event_type, start_time, end_time)
      |> limit(^limit)
      |> Repo.all()

    {:ok, events}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec replay_batches(binary(), keyword()) :: stream_result()
  def replay_batches(aggregate_id, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    query = """
    SELECT batch_number, event_count, events
    FROM replay_events($1::uuid, $2::integer)
    """

    Stream.resource(
      fn -> {aggregate_id, batch_size, 0} end,
      fn {agg_id, size, batch_num} ->
        case Repo.query(query, [agg_id, size]) do
          {:ok, %{rows: []}} ->
            {:halt, {agg_id, size, batch_num}}

          {:ok, %{rows: rows}} ->
            batches =
              Enum.map(rows, fn [batch_number, event_count, events_json] ->
                {batch_number, Jason.decode!(events_json)}
              end)

            {batches, {agg_id, size, batch_num + length(batches)}}

          {:error, _} ->
            {:halt, {agg_id, size, batch_num}}
        end
      end,
      fn _ -> :ok end
    )
  end

  @spec aggregate_stats(binary()) :: {:ok, map()} | {:error, term()}
  def aggregate_stats(aggregate_id) do
    stats =
      from(e in Event,
        where: e.aggregate_id == ^aggregate_id,
        select: %{
          event_count: count(e.id),
          latest_version: max(e.aggregate_version),
          first_event_at: min(e.occurred_at),
          last_event_at: max(e.occurred_at)
        }
      )
      |> Repo.one()

    event_types =
      from(e in Event,
        where: e.aggregate_id == ^aggregate_id,
        select: e.event_type,
        distinct: true
      )
      |> Repo.all()

    {:ok,
     Map.merge(stats || %{}, %{
       unique_event_types: length(event_types),
       event_types: event_types
     })}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec event_counts_by_type(DateTime.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def event_counts_by_type(start_time, end_time) do
    counts =
      from(e in Event,
        where: e.occurred_at >= ^start_time,
        where: e.occurred_at <= ^end_time,
        group_by: e.event_type,
        select: {e.event_type, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    {:ok, counts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_filter_query(opts) do
    Event
    |> maybe_filter_aggregate_id(opts[:aggregate_id])
    |> maybe_filter_aggregate_type(opts[:aggregate_type])
    |> maybe_filter_event_types(opts[:event_types])
    |> maybe_filter_time_range(opts[:start_time], opts[:end_time])
    |> maybe_filter_correlation(opts[:correlation_id])
    |> maybe_filter_actor(opts[:actor_id])
    |> maybe_filter_tags(opts[:tags])
    |> order_by([e], asc: e.occurred_at)
  end

  defp maybe_filter_aggregate_id(query, nil), do: query

  defp maybe_filter_aggregate_id(query, aggregate_id) do
    where(query, [e], e.aggregate_id == ^aggregate_id)
  end

  defp maybe_filter_aggregate_type(query, nil), do: query

  defp maybe_filter_aggregate_type(query, aggregate_type) do
    where(query, [e], e.aggregate_type == ^aggregate_type)
  end

  defp maybe_filter_event_types(query, nil), do: query
  defp maybe_filter_event_types(query, []), do: query

  defp maybe_filter_event_types(query, event_types) do
    where(query, [e], e.event_type in ^event_types)
  end

  defp maybe_filter_time_range(query, nil, nil), do: query

  defp maybe_filter_time_range(query, start_time, nil) do
    where(query, [e], e.occurred_at >= ^start_time)
  end

  defp maybe_filter_time_range(query, nil, end_time) do
    where(query, [e], e.occurred_at <= ^end_time)
  end

  defp maybe_filter_time_range(query, start_time, end_time) do
    query
    |> where([e], e.occurred_at >= ^start_time)
    |> where([e], e.occurred_at <= ^end_time)
  end

  defp maybe_filter_correlation(query, nil), do: query

  defp maybe_filter_correlation(query, correlation_id) do
    where(query, [e], e.correlation_id == ^correlation_id)
  end

  defp maybe_filter_actor(query, nil), do: query

  defp maybe_filter_actor(query, actor_id) do
    where(query, [e], e.actor_id == ^actor_id)
  end

  defp maybe_filter_tags(query, nil), do: query
  defp maybe_filter_tags(query, []), do: query

  defp maybe_filter_tags(query, tags) do
    where(query, [e], fragment("? && ?", e.tags, ^tags))
  end
end
