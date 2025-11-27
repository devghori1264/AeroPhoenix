defmodule Orchestrator.Metrics.SLADefinition do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.{MetricDefinition, SLAViolation}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type sla_status :: :meeting | :at_risk | :violated | :recovering
  @type comparison :: :gte | :lte | :eq | :gt | :lt
  schema "sla_definitions" do
    field(:name, :string)
    field(:description, :string)
    belongs_to(:metric, MetricDefinition, type: :binary_id)
    has_many(:violations, SLAViolation, foreign_key: :sla_id)
    field(:target_value, :float)
    field(:comparison, :string)
    field(:window_days, :integer, default: 30)
    field(:error_budget_percent, :float)
    field(:current_value, :float)
    field(:status, Ecto.Enum, values: [:meeting, :at_risk, :violated, :recovering])
    field(:last_violation_at, :utc_datetime_usec)
    field(:violation_count, :integer, default: 0)
    field(:service, :string)
    field(:team, :string)
    field(:enabled, :boolean, default: true)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(sla, attrs) do
    sla
    |> cast(attrs, [
      :name,
      :description,
      :metric_id,
      :target_value,
      :comparison,
      :window_days,
      :error_budget_percent,
      :current_value,
      :status,
      :service,
      :team,
      :enabled
    ])
    |> validate_required([:name, :service, :target_value, :comparison])
    |> validate_comparison()
    |> validate_window()
    |> validate_error_budget()
    |> unique_constraint(:name)
  end

  defp validate_comparison(changeset) do
    validate_inclusion(changeset, :comparison, [">=", "<=", "==", ">", "<"])
  end

  defp validate_window(changeset) do
    validate_number(changeset, :window_days,
      greater_than: 0,
      less_than_or_equal_to: 365,
      message: "must be between 1 and 365 days"
    )
  end

  defp validate_error_budget(changeset) do
    changeset
    |> validate_number(:error_budget_percent,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 100.0
    )
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update(sla, attrs) do
    sla
    |> changeset(attrs)
    |> Repo.update()
  end

  def enable(sla) do
    sla
    |> change(enabled: true)
    |> Repo.update()
  end

  def disable(sla) do
    sla
    |> change(enabled: false)
    |> Repo.update()
  end

  def list_enabled do
    from(s in __MODULE__,
      where: s.enabled == true,
      order_by: [asc: s.service, asc: s.name]
    )
    |> Repo.all()
  end

  def list_by_service(service) do
    from(s in __MODULE__,
      where: s.service == ^service and s.enabled == true,
      order_by: [asc: s.name]
    )
    |> Repo.all()
  end

  def list_by_team(team) do
    from(s in __MODULE__,
      where: s.team == ^team and s.enabled == true,
      order_by: [asc: s.service]
    )
    |> Repo.all()
  end

  def at_risk do
    from(s in __MODULE__,
      where: s.status == :at_risk and s.enabled == true,
      order_by: [asc: s.service]
    )
    |> Repo.all()
  end

  def violated do
    from(s in __MODULE__,
      where: s.status == :violated and s.enabled == true,
      order_by: [desc: s.last_violation_at]
    )
    |> Repo.all()
  end

  def check_compliance(sla) do
    query = """
    SELECT * FROM calculate_sla_compliance($1, $2)
    """

    case Repo.query(query, [sla.id, sla.window_days]) do
      {:ok, %{rows: [[current_value, target, compliance, budget, status]]}} ->
        sla
        |> change(
          current_value: current_value,
          status: String.to_existing_atom(status)
        )
        |> Repo.update()

        {:ok,
         %{
           current_value: current_value,
           target_value: target,
           compliance_percent: compliance,
           error_budget_remaining: budget,
           status: String.to_existing_atom(status)
         }}

      error ->
        Logger.error("SLA compliance calculation failed: #{inspect(error)}")
        {:error, :calculation_failed}
    end
  end

  def record_violation(sla, attrs) do
    Repo.transaction(fn ->
      violation_attrs =
        attrs
        |> Map.put(:sla_id, sla.id)
        |> Map.put(:target_value, sla.target_value)
        |> Map.put_new(:started_at, DateTime.utc_now())

      {:ok, violation} = SLAViolation.create(violation_attrs)

      sla
      |> change(
        status: :violated,
        last_violation_at: DateTime.utc_now(),
        violation_count: sla.violation_count + 1
      )
      |> Repo.update!()

      violation
    end)
  end

  def resolve_violation(sla, violation) do
    Repo.transaction(fn ->
      SLAViolation.resolve(violation)

      sla
      |> change(status: :recovering)
      |> Repo.update!()
    end)
  end

  def error_budget_burn_rate(sla, days \\ 7) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    query = """
    SELECT SUM(error_budget_consumed) / $2 as daily_burn_rate
    FROM sla_violations
    WHERE sla_id = $1
      AND started_at >= $3
    """

    case Repo.query(query, [sla.id, days, cutoff]) do
      {:ok, %{rows: [[burn_rate]]}} when not is_nil(burn_rate) ->
        {:ok, burn_rate}

      _ ->
        {:ok, 0.0}
    end
  end

  def predict_budget_exhaustion(sla) do
    with {:ok, compliance} <- check_compliance(sla),
         {:ok, burn_rate} <- error_budget_burn_rate(sla, 7) do
      remaining_budget = compliance.error_budget_remaining

      cond do
        burn_rate <= 0 ->
          {:ok, :safe}

        remaining_budget <= 0 ->
          {:ok, 0}

        true ->
          days_remaining = remaining_budget / burn_rate
          {:ok, Float.round(days_remaining, 1)}
      end
    end
  end

  def compliance_history(sla, days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    query = """
    SELECT
      DATE(timestamp) as date,
      AVG(avg) as daily_avg,
      $2 as target
    FROM metric_aggregates
    WHERE metric_id = $1
      AND interval = '1d'
      AND timestamp >= $3
    GROUP BY DATE(timestamp)
    ORDER BY date ASC
    """

    case Repo.query(query, [sla.metric_id, sla.target_value, cutoff]) do
      {:ok, %{rows: rows}} ->
        history =
          Enum.map(rows, fn [date, avg, target] ->
            compliance = calculate_compliance(avg, target, sla.comparison)

            %{
              date: date,
              actual_value: avg,
              target_value: target,
              compliance_percent: compliance,
              status: compliance_status(compliance)
            }
          end)

        {:ok, history}

      _ ->
        {:error, :query_failed}
    end
  end

  def summary_stats do
    query = """
    SELECT
      COUNT(*) FILTER (WHERE enabled = true) as total_enabled,
      COUNT(*) FILTER (WHERE status = 'meeting') as meeting_count,
      COUNT(*) FILTER (WHERE status = 'at_risk') as at_risk_count,
      COUNT(*) FILTER (WHERE status = 'violated') as violated_count,
      COUNT(*) FILTER (WHERE status = 'recovering') as recovering_count,
      AVG(current_value) FILTER (WHERE status = 'meeting') as avg_compliance_meeting
    FROM sla_definitions
    """

    case Repo.query(query) do
      {:ok, %{rows: [[total, meeting, at_risk, violated, recovering, avg_compliance]]}} ->
        {:ok,
         %{
           total_enabled: total,
           by_status: %{
             meeting: meeting,
             at_risk: at_risk,
             violated: violated,
             recovering: recovering
           },
           avg_compliance_when_meeting: avg_compliance
         }}

      _ ->
        {:error, :query_failed}
    end
  end

  def uptime_percentage(sla, days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    query = """
    SELECT
      COALESCE(SUM(EXTRACT(EPOCH FROM (COALESCE(ended_at, NOW()) - started_at))), 0) as violation_seconds
    FROM sla_violations
    WHERE sla_id = $1
      AND started_at >= $2
    """

    case Repo.query(query, [sla.id, cutoff]) do
      {:ok, %{rows: [[violation_seconds]]}} ->
        total_seconds = days * 86400
        uptime_seconds = total_seconds - violation_seconds
        uptime_percent = uptime_seconds / total_seconds * 100
        {:ok, Float.round(uptime_percent, 4)}

      _ ->
        {:error, :query_failed}
    end
  end

  def worst_performing(limit \\ 10) do
    from(s in __MODULE__,
      where: s.enabled == true,
      where: not is_nil(s.current_value),
      order_by: [asc: s.current_value],
      limit: ^limit
    )
    |> Repo.all()
  end

  def frequent_violators(limit \\ 10, days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    from(s in __MODULE__,
      left_join: v in assoc(s, :violations),
      where: s.enabled == true,
      where: is_nil(v.id) or v.started_at >= ^cutoff,
      group_by: s.id,
      having: count(v.id) > 0,
      select: %{
        sla: s,
        violation_count: count(v.id),
        avg_duration_minutes:
          fragment(
            "AVG(EXTRACT(EPOCH FROM (COALESCE(?, NOW()) - ?)) / 60)",
            v.ended_at,
            v.started_at
          )
      },
      order_by: [desc: count(v.id)],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp calculate_compliance(actual, target, comparison) do
    case comparison do
      ">=" -> if actual >= target, do: 100.0, else: actual / target * 100
      "<=" -> if actual <= target, do: 100.0, else: target / actual * 100
      ">" -> if actual > target, do: 100.0, else: actual / target * 100
      "<" -> if actual < target, do: 100.0, else: target / actual * 100
      "==" -> if actual == target, do: 100.0, else: 0.0
    end
  end

  defp compliance_status(compliance_percent) do
    cond do
      compliance_percent >= 100.0 -> :meeting
      compliance_percent >= 95.0 -> :recovering
      compliance_percent >= 90.0 -> :at_risk
      true -> :violated
    end
  end
end
