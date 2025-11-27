defmodule Orchestrator.Metrics.AlertInstance do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.AlertRule
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type alert_state :: :pending | :firing | :resolved | :silenced | :acked
  @type severity :: :info | :warning | :critical
  schema "alert_instances" do
    belongs_to(:alert_rule, AlertRule, type: :binary_id)

    field(:state, Ecto.Enum,
      values: [:pending, :firing, :resolved, :silenced, :acked],
      default: :pending
    )

    field(:severity, Ecto.Enum, values: [:info, :warning, :critical])
    field(:started_at, :utc_datetime_usec)
    field(:resolved_at, :utc_datetime_usec)
    field(:silenced_until, :utc_datetime_usec)
    field(:labels, :map, default: %{})
    field(:current_value, :float)
    field(:threshold, :float)
    field(:description, :string)
    field(:summary, :string)
    field(:runbook_url, :string)
    field(:acknowledged_at, :utc_datetime_usec)
    field(:acknowledged_by, :binary_id)
    field(:notified_at, :utc_datetime_usec)
    field(:notification_count, :integer, default: 0)
    field(:notification_channels, {:array, :string}, default: [])
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :alert_rule_id,
      :state,
      :severity,
      :started_at,
      :resolved_at,
      :silenced_until,
      :labels,
      :current_value,
      :threshold,
      :description,
      :summary,
      :runbook_url,
      :acknowledged_at,
      :acknowledged_by,
      :notified_at,
      :notification_count,
      :notification_channels
    ])
    |> validate_required([:alert_rule_id, :state, :severity, :started_at])
    |> validate_state_transition()
    |> put_default_started_at()
  end

  defp validate_state_transition(changeset) do
    old_state = get_field(changeset, :state, :pending)
    new_state = get_change(changeset, :state)

    if new_state && !valid_transition?(old_state, new_state) do
      add_error(
        changeset,
        :state,
        "invalid state transition from #{old_state} to #{new_state}"
      )
    else
      changeset
    end
  end

  defp valid_transition?(from, to) do
    transitions = %{
      pending: [:firing, :resolved],
      firing: [:resolved, :acked, :silenced],
      acked: [:resolved, :silenced],
      silenced: [:firing, :resolved],
      resolved: []
    }

    to in Map.get(transitions, from, [])
  end

  defp put_default_started_at(changeset) do
    if get_field(changeset, :started_at) do
      changeset
    else
      put_change(changeset, :started_at, DateTime.utc_now())
    end
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def fire(instance) do
    instance
    |> change(state: :firing)
    |> Repo.update()
  end

  def acknowledge(instance, user_id) do
    instance
    |> change(
      state: :acked,
      acknowledged_at: DateTime.utc_now(),
      acknowledged_by: user_id
    )
    |> Repo.update()
  end

  def silence(instance, duration_seconds) do
    silenced_until = DateTime.utc_now() |> DateTime.add(duration_seconds, :second)

    instance
    |> change(state: :silenced, silenced_until: silenced_until)
    |> Repo.update()
  end

  def resolve(instance) do
    instance
    |> change(state: :resolved, resolved_at: DateTime.utc_now())
    |> Repo.update()
  end

  def update_value(instance, value) do
    instance
    |> change(current_value: value)
    |> Repo.update()
  end

  def record_notification(instance, channels) do
    instance
    |> change(
      notified_at: DateTime.utc_now(),
      notification_count: instance.notification_count + 1,
      notification_channels: channels
    )
    |> Repo.update()
  end

  def firing do
    from(i in __MODULE__,
      where: i.state == :firing,
      order_by: [desc: i.severity, desc: i.started_at],
      preload: :alert_rule
    )
    |> Repo.all()
  end

  def pending do
    from(i in __MODULE__,
      where: i.state == :pending,
      order_by: [desc: i.severity, desc: i.started_at],
      preload: :alert_rule
    )
    |> Repo.all()
  end

  def unacknowledged(severity \\ nil) do
    query =
      from(i in __MODULE__,
        where: i.state == :firing,
        order_by: [desc: i.severity, desc: i.started_at],
        preload: :alert_rule
      )

    query =
      if severity do
        from(i in query, where: i.severity == ^severity)
      else
        query
      end

    Repo.all(query)
  end

  def for_rule(rule_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    states = Keyword.get(opts, :states)

    query =
      from(i in __MODULE__,
        where: i.alert_rule_id == ^rule_id,
        order_by: [desc: i.started_at],
        limit: ^limit
      )

    query =
      if states do
        from(i in query, where: i.state in ^states)
      else
        query
      end

    Repo.all(query)
  end

  def recent(hours \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    from(i in __MODULE__,
      where: i.started_at >= ^cutoff,
      order_by: [desc: i.started_at],
      preload: :alert_rule
    )
    |> Repo.all()
  end

  def need_notification(renotify_interval_seconds \\ 3600) do
    cutoff = DateTime.utc_now() |> DateTime.add(-renotify_interval_seconds, :second)

    from(i in __MODULE__,
      where: i.state == :firing,
      where: is_nil(i.notified_at) or i.notified_at <= ^cutoff,
      order_by: [desc: i.severity, asc: i.notified_at],
      preload: :alert_rule
    )
    |> Repo.all()
  end

  def cleanup_resolved(retention_days \\ 90) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86400, :second)

    from(i in __MODULE__,
      where: i.state == :resolved,
      where: i.resolved_at < ^cutoff
    )
    |> Repo.delete_all()
  end

  def unsilence_expired do
    now = DateTime.utc_now()

    from(i in __MODULE__,
      where: i.state == :silenced,
      where: i.silenced_until <= ^now
    )
    |> Repo.update_all(set: [state: :firing])
  end

  def stats(hours \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    query = """
    SELECT
      COUNT(*) FILTER (WHERE state = 'firing') as firing_count,
      COUNT(*) FILTER (WHERE state = 'pending') as pending_count,
      COUNT(*) FILTER (WHERE state = 'acked') as acked_count,
      COUNT(*) FILTER (WHERE state = 'silenced') as silenced_count,
      COUNT(*) FILTER (WHERE state = 'resolved') as resolved_count,
      COUNT(*) FILTER (WHERE severity = 'critical') as critical_count,
      COUNT(*) FILTER (WHERE severity = 'warning') as warning_count,
      COUNT(*) FILTER (WHERE severity = 'info') as info_count,
      AVG(EXTRACT(EPOCH FROM (COALESCE(resolved_at, NOW()) - started_at))) as avg_duration_seconds,
      SUM(notification_count) as total_notifications
    FROM alert_instances
    WHERE started_at >= $1
    """

    case Repo.query(query, [cutoff]) do
      {:ok,
       %{
         rows: [
           [
             firing,
             pending,
             acked,
             silenced,
             resolved,
             critical,
             warning,
             info,
             avg_duration,
             total_notifications
           ]
         ]
       }} ->
        {:ok,
         %{
           by_state: %{
             firing: firing,
             pending: pending,
             acked: acked,
             silenced: silenced,
             resolved: resolved
           },
           by_severity: %{
             critical: critical,
             warning: warning,
             info: info
           },
           avg_duration_seconds: avg_duration,
           total_notifications: total_notifications
         }}

      _ ->
        {:error, :query_failed}
    end
  end

  def mttr_by_severity(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    query = """
    SELECT
      severity,
      AVG(EXTRACT(EPOCH FROM (resolved_at - started_at))) as avg_seconds,
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (resolved_at - started_at))) as p50_seconds,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (resolved_at - started_at))) as p95_seconds
    FROM alert_instances
    WHERE state = 'resolved'
      AND started_at >= $1
      AND resolved_at IS NOT NULL
    GROUP BY severity
    """

    case Repo.query(query, [cutoff]) do
      {:ok, %{rows: rows}} ->
        mttr =
          Enum.map(rows, fn [severity, avg, p50, p95] ->
            {String.to_existing_atom(severity),
             %{
               avg_seconds: avg,
               p50_seconds: p50,
               p95_seconds: p95
             }}
          end)
          |> Enum.into(%{})

        {:ok, mttr}

      _ ->
        {:error, :query_failed}
    end
  end
end
