defmodule Orchestrator.Metrics.AlertRule do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.{MetricDefinition, AlertInstance}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type severity :: :info | :warning | :critical
  @type alert_state :: :pending | :firing | :resolved | :silenced | :acked
  schema "alert_rules" do
    field(:name, :string)
    field(:severity, Ecto.Enum, values: [:info, :warning, :critical])
    field(:enabled, :boolean, default: true)
    belongs_to(:metric, MetricDefinition, type: :binary_id)
    has_many(:instances, AlertInstance, foreign_key: :alert_rule_id)
    field(:query, :string)
    field(:condition, :string)
    field(:threshold, :float)
    field(:duration_seconds, :integer, default: 60)
    field(:label_matchers, :map, default: %{})
    field(:description, :string)
    field(:summary, :string)
    field(:runbook_url, :string)
    field(:notification_channels, {:array, :string}, default: ["email"])
    field(:evaluation_interval_seconds, :integer, default: 60)
    field(:last_evaluated_at, :utc_datetime_usec)

    field(:last_state, Ecto.Enum,
      values: [:pending, :firing, :resolved, :silenced, :acked],
      default: :resolved
    )

    field(:created_by, :binary_id)
    field(:team, :string)
    field(:priority, :integer, default: 0)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :name,
      :severity,
      :enabled,
      :metric_id,
      :query,
      :condition,
      :threshold,
      :duration_seconds,
      :label_matchers,
      :description,
      :summary,
      :runbook_url,
      :notification_channels,
      :evaluation_interval_seconds,
      :created_by,
      :team,
      :priority
    ])
    |> validate_required([:name, :severity, :query, :condition, :threshold])
    |> validate_condition()
    |> validate_duration()
    |> validate_notification_channels()
    |> unique_constraint(:name)
  end

  defp validate_condition(changeset) do
    validate_inclusion(changeset, :condition, [">", "<", ">=", "<=", "==", "!="])
  end

  defp validate_duration(changeset) do
    changeset
    |> validate_number(:duration_seconds,
      greater_than: 0,
      less_than_or_equal_to: 86400,
      message: "must be between 1 second and 1 day"
    )
    |> validate_number(:evaluation_interval_seconds,
      greater_than: 0,
      less_than_or_equal_to: 3600,
      message: "must be between 1 second and 1 hour"
    )
  end

  defp validate_notification_channels(changeset) do
    case get_field(changeset, :notification_channels) do
      nil ->
        changeset

      channels ->
        valid_channels = ["email", "slack", "pagerduty", "webhook", "sms"]

        if Enum.all?(channels, &(&1 in valid_channels)) do
          changeset
        else
          add_error(
            changeset,
            :notification_channels,
            "must be one of: #{Enum.join(valid_channels, ", ")}"
          )
        end
    end
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update(rule, attrs) do
    rule
    |> changeset(attrs)
    |> Repo.update()
  end

  def enable(rule) do
    rule
    |> change(enabled: true)
    |> Repo.update()
  end

  def disable(rule) do
    rule
    |> change(enabled: false)
    |> Repo.update()
  end

  def list_enabled do
    from(r in __MODULE__,
      where: r.enabled == true,
      order_by: [desc: r.priority, asc: r.name]
    )
    |> Repo.all()
  end

  def list_by_severity(severity) do
    from(r in __MODULE__,
      where: r.severity == ^severity and r.enabled == true,
      order_by: [desc: r.priority]
    )
    |> Repo.all()
  end

  def list_by_team(team) do
    from(r in __MODULE__,
      where: r.team == ^team and r.enabled == true,
      order_by: [desc: r.priority]
    )
    |> Repo.all()
  end

  def due_for_evaluation do
    now = DateTime.utc_now()

    from(r in __MODULE__,
      where: r.enabled == true,
      where:
        is_nil(r.last_evaluated_at) or
          r.last_evaluated_at <=
            datetime_add(^now, -1 * r.evaluation_interval_seconds, "second")
    )
    |> Repo.all()
  end

  def firing do
    from(r in __MODULE__,
      where: r.last_state == :firing,
      order_by: [desc: r.severity, desc: r.priority]
    )
    |> Repo.all()
  end

  def update_evaluation(rule, state) do
    rule
    |> change(last_evaluated_at: DateTime.utc_now(), last_state: state)
    |> Repo.update()
  end

  def firing_count_by_severity do
    from(r in __MODULE__,
      where: r.last_state == :firing,
      group_by: r.severity,
      select: {r.severity, count(r.id)}
    )
    |> Repo.all()
    |> Enum.into(%{})
  end

  def with_active_instance_counts do
    from(r in __MODULE__,
      left_join: i in assoc(r, :instances),
      where: r.enabled == true,
      where: is_nil(i.id) or i.state in [:pending, :firing],
      group_by: r.id,
      select: %{
        rule: r,
        active_instances: count(i.id),
        last_fired:
          fragment(
            "MAX(CASE WHEN ? = 'firing' THEN ? END)",
            i.state,
            i.started_at
          )
      },
      order_by: [desc: r.severity, desc: r.priority]
    )
    |> Repo.all()
  end

  def silence(rule, duration_seconds) do
    silence_until = DateTime.utc_now() |> DateTime.add(duration_seconds, :second)

    from(i in AlertInstance,
      where: i.alert_rule_id == ^rule.id,
      where: i.state in [:pending, :firing]
    )
    |> Repo.update_all(set: [state: :silenced, silenced_until: silence_until])

    rule
    |> change(last_state: :silenced)
    |> Repo.update()
  end

  def summary_stats do
    query = """
    SELECT
      COUNT(*) FILTER (WHERE enabled = true) as total_enabled,
      COUNT(*) FILTER (WHERE enabled = false) as total_disabled,
      COUNT(*) FILTER (WHERE last_state = 'firing') as currently_firing,
      COUNT(*) FILTER (WHERE last_state = 'pending') as currently_pending,
      COUNT(*) FILTER (WHERE severity = 'critical') as critical_count,
      COUNT(*) FILTER (WHERE severity = 'warning') as warning_count,
      COUNT(*) FILTER (WHERE severity = 'info') as info_count
    FROM alert_rules
    """

    case Repo.query(query) do
      {:ok, %{rows: [[total_enabled, total_disabled, firing, pending, critical, warning, info]]}} ->
        {:ok,
         %{
           total_enabled: total_enabled,
           total_disabled: total_disabled,
           currently_firing: firing,
           currently_pending: pending,
           by_severity: %{
             critical: critical,
             warning: warning,
             info: info
           }
         }}

      _ ->
        {:error, :query_failed}
    end
  end
end
