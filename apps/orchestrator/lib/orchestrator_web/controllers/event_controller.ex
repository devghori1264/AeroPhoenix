defmodule OrchestratorWeb.EventController do
  use OrchestratorWeb, :controller
  require Logger
  alias Orchestrator.Repo
  import Ecto.Query

  def list_aggregates(conn, params) do
    aggregate_type = params["type"]

    query =
      from(e in "events",
        group_by: [e.aggregate_id, e.aggregate_type],
        select: %{
          aggregate_id: e.aggregate_id,
          aggregate_type: e.aggregate_type,
          event_count: count(e.id),
          latest_version: max(e.aggregate_version),
          first_event_at: min(e.occurred_at),
          last_event_at: max(e.occurred_at)
        }
      )

    query =
      if aggregate_type do
        where(query, [e], e.aggregate_type == ^aggregate_type)
      else
        query
      end

    aggregates = Repo.all(query)

    enriched_aggregates =
      Enum.map(aggregates, fn agg ->
        event_types = get_aggregate_event_types(Map.get(agg, :aggregate_id))

        Map.merge(agg, %{
          unique_event_types: length(event_types),
          event_types: event_types
        })
      end)

    json(conn, %{aggregates: enriched_aggregates})
  end

  def show(conn, %{"aggregate_id" => aggregate_id} = params) do
    query = build_event_query(aggregate_id, params)
    events = Repo.all(query)

    json(conn, %{
      aggregate_id: aggregate_id,
      events: Enum.map(events, &format_event/1),
      count: length(events)
    })
  end

  def rebuild(conn, %{"aggregate_id" => aggregate_id} = params) do
    to_version = parse_int(params["version"])
    time_travel = params["time"]
    no_snapshot = params["no_snapshot"] == "true"

    {base_state, from_version} =
      if no_snapshot do
        {%{}, 0}
      else
        load_snapshot(aggregate_id, to_version)
      end

    query =
      from(e in "events",
        where: e.aggregate_id == ^aggregate_id,
        where: e.aggregate_version > ^from_version,
        order_by: [asc: e.aggregate_version]
      )

    query =
      cond do
        to_version && to_version > 0 ->
          where(query, [e], e.aggregate_version <= ^to_version)

        time_travel ->
          case parse_timestamp(time_travel) do
            {:ok, timestamp} ->
              where(query, [e], e.occurred_at <= ^timestamp)

            :error ->
              query
          end

        true ->
          query
      end

    events = Repo.all(query)
    final_state = apply_events(base_state, events)

    result =
      Map.merge(final_state, %{
        __metadata__: %{
          aggregate_id: aggregate_id,
          version: to_version || length(events) + from_version,
          event_count: length(events),
          snapshot_used: !no_snapshot && from_version > 0,
          reconstructed_at: DateTime.utc_now()
        }
      })

    json(conn, result)
  end

  def diff(conn, %{"aggregate_id" => aggregate_id} = params) do
    from_version = parse_int(params["from"]) || 0
    to_version = parse_int(params["to"]) || 0

    if from_version == 0 do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "from_version is required"})
    else
      state_from = rebuild_state_at_version(aggregate_id, from_version)
      state_to = rebuild_state_at_version(aggregate_id, to_version)
      diff = compute_state_diff(state_from, state_to)

      json(conn, %{
        aggregate_id: aggregate_id,
        from_version: from_version,
        to_version: to_version,
        diff: diff
      })
    end
  end

  def search(conn, %{"q" => query} = params) do
    event_types = parse_list(params["types"])
    limit = parse_int(params["limit"]) || 100

    search_query =
      from(e in "events",
        where:
          fragment(
            "to_tsvector('english', ?::text) @@ plainto_tsquery('english', ?)",
            e.data,
            ^query
          ),
        order_by: [desc: e.occurred_at],
        limit: ^limit
      )

    search_query =
      if event_types && length(event_types) > 0 do
        where(search_query, [e], e.event_type in ^event_types)
      else
        search_query
      end

    events = Repo.all(search_query)

    json(conn, %{
      query: query,
      events: Enum.map(events, &format_event/1),
      count: length(events)
    })
  end

  def trace(conn, %{"correlation_id" => correlation_id} = params) do
    limit = parse_int(params["limit"]) || 1000

    query =
      from(e in "events",
        where: e.correlation_id == ^correlation_id,
        order_by: [asc: e.occurred_at],
        limit: ^limit
      )

    events = Repo.all(query)

    workflow =
      events
      |> Enum.group_by(& &1.aggregate_id)
      |> Enum.map(fn {agg_id, agg_events} ->
        %{
          aggregate_id: agg_id,
          aggregate_type: List.first(agg_events).aggregate_type,
          event_count: length(agg_events),
          events: Enum.map(agg_events, &format_event/1)
        }
      end)

    json(conn, %{
      correlation_id: correlation_id,
      workflow: workflow,
      total_events: length(events),
      affected_aggregates: length(workflow)
    })
  end

  defp build_event_query(aggregate_id, params) do
    from_version = parse_int(params["from_version"]) || 0
    to_version = parse_int(params["to_version"])
    event_types = parse_list(params["event_types"])
    tags = parse_list(params["tags"])
    limit = parse_int(params["limit"]) || 1000

    query =
      from(e in "events",
        where: e.aggregate_id == ^aggregate_id,
        where: e.aggregate_version > ^from_version,
        order_by: [asc: e.aggregate_version],
        limit: ^limit
      )

    query =
      if to_version do
        where(query, [e], e.aggregate_version <= ^to_version)
      else
        query
      end

    query =
      if event_types && length(event_types) > 0 do
        where(query, [e], e.event_type in ^event_types)
      else
        query
      end

    query =
      if tags && length(tags) > 0 do
        Enum.reduce(tags, query, fn tag, q ->
          where(q, [e], ^tag in e.tags)
        end)
      else
        query
      end

    query =
      if params["since"] do
        case parse_timestamp(params["since"]) do
          {:ok, since} -> where(query, [e], e.occurred_at >= ^since)
          :error -> query
        end
      else
        query
      end

    if params["until"] do
      case parse_timestamp(params["until"]) do
        {:ok, until_ts} -> where(query, [e], e.occurred_at <= ^until_ts)
        :error -> query
      end
    else
      query
    end
  end

  defp load_snapshot(aggregate_id, to_version) do
    query =
      from(s in "event_snapshots",
        where: s.aggregate_id == ^aggregate_id,
        order_by: [desc: s.aggregate_version],
        limit: 1
      )

    query =
      if to_version && to_version > 0 do
        where(query, [s], s.aggregate_version <= ^to_version)
      else
        query
      end

    case Repo.one(query) do
      nil ->
        {%{}, 0}

      snapshot ->
        {snapshot.state, snapshot.aggregate_version}
    end
  end

  defp rebuild_state_at_version(aggregate_id, version) do
    {base_state, from_version} = load_snapshot(aggregate_id, version)

    query =
      from(e in "events",
        where: e.aggregate_id == ^aggregate_id,
        where: e.aggregate_version > ^from_version,
        where: e.aggregate_version <= ^version,
        order_by: [asc: e.aggregate_version]
      )

    events = Repo.all(query)
    apply_events(base_state, events)
  end

  defp apply_events(initial_state, events) do
    Enum.reduce(events, initial_state, fn event, state ->
      apply_event(state, event)
    end)
  end

  defp apply_event(state, event) do
    Map.merge(state, event.data)
  end

  defp compute_state_diff(state_from, state_to) do
    all_keys = MapSet.new(Map.keys(state_from) ++ Map.keys(state_to))

    {added, removed, changed} =
      Enum.reduce(all_keys, {%{}, %{}, %{}}, fn key, {add, rem, chg} ->
        from_val = Map.get(state_from, key)
        to_val = Map.get(state_to, key)

        cond do
          is_nil(from_val) && !is_nil(to_val) ->
            {Map.put(add, key, to_val), rem, chg}

          !is_nil(from_val) && is_nil(to_val) ->
            {add, Map.put(rem, key, from_val), chg}

          from_val != to_val ->
            {add, rem, Map.put(chg, key, %{from: from_val, to: to_val})}

          true ->
            {add, rem, chg}
        end
      end)

    %{
      added: added,
      removed: removed,
      changed: changed
    }
  end

  defp get_aggregate_event_types(aggregate_id) do
    query =
      from(e in "events",
        where: e.aggregate_id == ^aggregate_id,
        select: e.event_type,
        distinct: true
      )

    Repo.all(query)
  end

  defp format_event(event) do
    %{
      id: event.id,
      event_type: event.event_type,
      aggregate_id: event.aggregate_id,
      aggregate_type: event.aggregate_type,
      aggregate_version: event.aggregate_version,
      data: event.data,
      metadata: event.metadata,
      tags: event.tags || [],
      correlation_id: event.correlation_id,
      occurred_at: event.occurred_at,
      recorded_at: event.recorded_at
    }
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_int(num) when is_integer(num), do: num
  defp parse_list(nil), do: nil
  defp parse_list(""), do: nil

  defp parse_list(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_timestamp(str) when is_binary(str) do
    case parse_duration(str) do
      {:ok, duration} ->
        {:ok, DateTime.add(DateTime.utc_now(), -duration, :second)}

      :error ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> :error
        end
    end
  end

  defp parse_duration(str) do
    cond do
      String.ends_with?(str, "s") ->
        parse_duration_value(str, "s", 1)

      String.ends_with?(str, "m") ->
        parse_duration_value(str, "m", 60)

      String.ends_with?(str, "h") ->
        parse_duration_value(str, "h", 3600)

      String.ends_with?(str, "d") ->
        parse_duration_value(str, "d", 86400)

      true ->
        :error
    end
  end

  defp parse_duration_value(str, suffix, multiplier) do
    str
    |> String.trim_trailing(suffix)
    |> Integer.parse()
    |> case do
      {num, ""} -> {:ok, num * multiplier}
      _ -> :error
    end
  end
end
