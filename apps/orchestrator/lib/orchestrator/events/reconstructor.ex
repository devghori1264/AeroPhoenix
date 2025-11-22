defmodule Orchestrator.Events.Reconstructor do
  require Logger
  alias Orchestrator.Events.{Event, Reader, Snapshot, Writer}
  alias Orchestrator.Repo

  @type rebuild_opts :: [
          to_version: integer() | nil,
          use_snapshot: boolean(),
          validate: boolean()
        ]
  @type diff_opts :: [
          from_version: integer(),
          to_version: integer()
        ]
  @type state :: map()
  @type rebuild_result :: {:ok, state()} | {:error, term()}
  @type diff_result :: {:ok, map()} | {:error, term()}
  @default_snapshot_interval 100
  @spec rebuild(binary(), rebuild_opts()) :: rebuild_result()
  def rebuild(aggregate_id, opts \\ []) do
    to_version = Keyword.get(opts, :to_version)
    use_snapshot = Keyword.get(opts, :use_snapshot, true)
    validate = Keyword.get(opts, :validate, false)

    with {:ok, {snapshot, events}} <-
           fetch_events_for_rebuild(aggregate_id, to_version, use_snapshot),
         :ok <- maybe_validate_stream(aggregate_id, events, validate),
         {:ok, state} <- apply_events(snapshot, events) do
      {:ok, state}
    end
  rescue
    e ->
      Logger.error("Failed to rebuild aggregate #{aggregate_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @spec time_travel(binary(), DateTime.t()) :: rebuild_result()
  def time_travel(aggregate_id, timestamp) do
    with {:ok, {snapshot, events}} <- fetch_events_for_timestamp(aggregate_id, timestamp),
         {:ok, state} <- apply_events(snapshot, events) do
      Logger.info("Time-traveled aggregate #{aggregate_id} to #{timestamp}")
      {:ok, state}
    end
  rescue
    e ->
      Logger.error("Failed to time-travel aggregate #{aggregate_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @spec diff(binary(), diff_opts()) :: diff_result()
  def diff(aggregate_id, opts) do
    from_version = Keyword.fetch!(opts, :from_version)
    to_version = Keyword.fetch!(opts, :to_version)

    with {:ok, state_from} <- rebuild(aggregate_id, to_version: from_version),
         {:ok, state_to} <- rebuild(aggregate_id, to_version: to_version) do
      diff = compute_diff(state_from, state_to)
      {:ok, diff}
    end
  rescue
    e ->
      Logger.error(
        "Failed to compute diff for aggregate #{aggregate_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  @spec create_snapshot(binary(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, term()}
  def create_snapshot(aggregate_id, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, state} <- rebuild(aggregate_id, use_snapshot: true),
         version <- Map.get(state, :version) || get_latest_version(aggregate_id) do
      Snapshot.create_snapshot(
        aggregate_id,
        state,
        aggregate_version: version,
        metadata:
          Map.merge(metadata, %{
            created_by: :reconstructor,
            created_at: DateTime.utc_now()
          })
      )
    end
  rescue
    e ->
      Logger.error(
        "Failed to create snapshot for aggregate #{aggregate_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  @spec auto_snapshot(binary(), keyword()) ::
          {:ok, Snapshot.t() | :skipped} | {:error, term()}
  def auto_snapshot(aggregate_id, opts \\ []) do
    interval = Keyword.get(opts, :interval, @default_snapshot_interval)

    with {:ok, latest_version} <- get_latest_version_result(aggregate_id),
         snapshot <- Snapshot.latest_for_aggregate(aggregate_id) do
      last_snapshot_version = if snapshot, do: snapshot.aggregate_version, else: 0
      events_since_snapshot = latest_version - last_snapshot_version

      if events_since_snapshot >= interval do
        Logger.info(
          "Creating auto-snapshot for aggregate #{aggregate_id} " <>
            "(#{events_since_snapshot} events since last snapshot)"
        )

        create_snapshot(aggregate_id,
          metadata: %{
            auto: true,
            interval: interval,
            events_since_last: events_since_snapshot
          }
        )
      else
        {:ok, :skipped}
      end
    end
  rescue
    e ->
      Logger.error("Failed auto-snapshot for aggregate #{aggregate_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @spec validate_stream(binary()) :: :ok | {:error, list(String.t())}
  def validate_stream(aggregate_id) do
    case Reader.read_stream(aggregate_id, limit: 100_000) do
      {:ok, events} ->
        errors = validate_events(events)

        if Enum.empty?(errors) do
          :ok
        else
          {:error, errors}
        end

      {:error, reason} ->
        {:error, ["Failed to read events: #{reason}"]}
    end
  end

  defp fetch_events_for_rebuild(aggregate_id, to_version, true = _use_snapshot) do
    Reader.read_from_snapshot(aggregate_id, to_version: to_version)
  end

  defp fetch_events_for_rebuild(aggregate_id, to_version, false = _use_snapshot) do
    case Reader.read_stream(aggregate_id, to_version: to_version) do
      {:ok, events} -> {:ok, {nil, events}}
      error -> error
    end
  end

  defp fetch_events_for_timestamp(aggregate_id, timestamp) do
    snapshot = Snapshot.latest_for_aggregate(aggregate_id)

    from_version =
      if snapshot && DateTime.compare(snapshot.created_at, timestamp) == :lt do
        snapshot.aggregate_version
      else
        0
      end

    events_query =
      Event
      |> Event.for_aggregate(aggregate_id)
      |> Ecto.Query.where([e], e.occurred_at <= ^timestamp)
      |> Ecto.Query.where([e], e.aggregate_version > ^from_version)
      |> Ecto.Query.order_by([e], asc: e.aggregate_version)

    events = Repo.all(events_query)

    snapshot_to_use =
      if snapshot && DateTime.compare(snapshot.created_at, timestamp) == :lt do
        snapshot
      else
        nil
      end

    {:ok, {snapshot_to_use, events}}
  end

  defp apply_events(nil, events) do
    state = Enum.reduce(events, %{version: 0}, &apply_event/2)
    {:ok, state}
  end

  defp apply_events(%Snapshot{} = snapshot, events) do
    initial_state = Map.put(snapshot.state, :version, snapshot.aggregate_version)
    state = Enum.reduce(events, initial_state, &apply_event/2)
    {:ok, state}
  end

  defp apply_event(%Event{} = event, state) do
    new_state = reduce_event(event, state)
    Map.put(new_state, :version, event.aggregate_version)
  end

  defp reduce_event(%Event{event_type: :machine_created, data: data}, _state) do
    %{
      id: data["id"],
      name: data["name"],
      status: :created,
      region: data["region"],
      config: data["config"] || %{},
      created_at: data["created_at"]
    }
  end

  defp reduce_event(%Event{event_type: :machine_started, data: data}, state) do
    %{state | status: :running, started_at: data["started_at"]}
  end

  defp reduce_event(%Event{event_type: :machine_stopped, data: data}, state) do
    %{state | status: :stopped, stopped_at: data["stopped_at"]}
  end

  defp reduce_event(%Event{event_type: :machine_destroyed}, state) do
    %{state | status: :destroyed, destroyed_at: DateTime.utc_now()}
  end

  defp reduce_event(%Event{event_type: :state_transition_started, data: data}, state) do
    %{state | status: :transitioning, target_state: data["to_state"]}
  end

  defp reduce_event(%Event{event_type: :state_transition_completed, data: data}, state) do
    state
    |> Map.put(:status, String.to_existing_atom(data["to_state"]))
    |> Map.delete(:target_state)
  end

  defp reduce_event(%Event{event_type: :state_transition_failed, data: data}, state) do
    state
    |> Map.put(:status, :error)
    |> Map.put(:error, data["error"])
    |> Map.delete(:target_state)
  end

  defp reduce_event(%Event{event_type: :config_updated, data: data}, state) do
    new_config = Map.merge(state.config || %{}, data["config"])
    %{state | config: new_config}
  end

  defp reduce_event(%Event{event_type: :migration_initiated, data: data}, state) do
    %{state | migration_state: :migrating, target_region: data["target_region"]}
  end

  defp reduce_event(%Event{event_type: :migration_completed, data: data}, state) do
    state
    |> Map.put(:region, data["target_region"])
    |> Map.put(:migration_state, :completed)
    |> Map.delete(:target_region)
  end

  defp reduce_event(%Event{event_type: :resource_allocated, data: data}, state) do
    resources = Map.get(state, :resources, %{})
    updated_resources = Map.put(resources, data["resource_type"], data["resource_id"])
    %{state | resources: updated_resources}
  end

  defp reduce_event(%Event{event_type: :resource_deallocated, data: data}, state) do
    resources = Map.get(state, :resources, %{})
    updated_resources = Map.delete(resources, data["resource_type"])
    %{state | resources: updated_resources}
  end

  defp reduce_event(%Event{event_type: :health_check_failed, data: data}, state) do
    failures = Map.get(state, :health_failures, 0)
    %{state | health_failures: failures + 1, last_health_error: data["error"]}
  end

  defp reduce_event(%Event{event_type: :health_check_recovered}, state) do
    state
    |> Map.put(:health_failures, 0)
    |> Map.delete(:last_health_error)
  end

  defp reduce_event(_event, state), do: state

  defp compute_diff(state_from, state_to) do
    keys_from = MapSet.new(Map.keys(state_from))
    keys_to = MapSet.new(Map.keys(state_to))
    added_keys = MapSet.difference(keys_to, keys_from)
    removed_keys = MapSet.difference(keys_from, keys_to)
    common_keys = MapSet.intersection(keys_from, keys_to)

    changed =
      common_keys
      |> Enum.filter(fn key ->
        Map.get(state_from, key) != Map.get(state_to, key)
      end)
      |> Map.new(fn key ->
        {key, %{from: Map.get(state_from, key), to: Map.get(state_to, key)}}
      end)

    %{
      added: Map.take(state_to, MapSet.to_list(added_keys)),
      removed: Map.take(state_from, MapSet.to_list(removed_keys)),
      changed: changed
    }
  end

  defp maybe_validate_stream(_aggregate_id, _events, false), do: :ok

  defp maybe_validate_stream(aggregate_id, events, true) do
    case validate_events(events) do
      [] -> :ok
      errors -> {:error, "Invalid event stream for #{aggregate_id}: #{inspect(errors)}"}
    end
  end

  defp validate_events([]), do: []

  defp validate_events(events) do
    events
    |> Enum.sort_by(& &1.aggregate_version)
    |> Enum.reduce({[], nil, nil}, fn event, {errors, prev_version, prev_timestamp} ->
      new_errors = []

      new_errors =
        if prev_version && event.aggregate_version != prev_version + 1 do
          [
            "Gap in version sequence: expected #{prev_version + 1}, got #{event.aggregate_version}"
            | new_errors
          ]
        else
          new_errors
        end

      new_errors =
        if prev_timestamp && DateTime.compare(event.occurred_at, prev_timestamp) == :lt do
          ["Non-monotonic timestamp at version #{event.aggregate_version}" | new_errors]
        else
          new_errors
        end

      {errors ++ new_errors, event.aggregate_version, event.occurred_at}
    end)
    |> elem(0)
  end

  defp get_latest_version(aggregate_id) do
    case Event.latest_version(aggregate_id) |> Repo.one() do
      nil -> 0
      version -> version
    end
  end

  defp get_latest_version_result(aggregate_id) do
    {:ok, get_latest_version(aggregate_id)}
  end
end
