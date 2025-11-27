defmodule Orchestrator.Cost.Budget do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Cost.BudgetAlert

  @type t :: %__MODULE__{
          id: integer(),
          name: String.t(),
          description: String.t() | nil,
          scope_type: String.t(),
          scope_value: String.t() | nil,
          tags: list(String.t()),
          monthly_limit: Decimal.t(),
          daily_limit: Decimal.t() | nil,
          currency: String.t(),
          warning_threshold: integer(),
          critical_threshold: integer(),
          current_month_spend: Decimal.t(),
          current_day_spend: Decimal.t(),
          projected_month_spend: Decimal.t() | nil,
          start_date: Date.t(),
          end_date: Date.t() | nil,
          is_active: boolean(),
          last_alert_sent_at: DateTime.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
  schema "budgets" do
    field(:name, :string)
    field(:description, :string)
    field(:scope_type, :string)
    field(:scope_value, :string)
    field(:tags, {:array, :string}, default: [])
    field(:monthly_limit, :decimal)
    field(:daily_limit, :decimal)
    field(:currency, :string, default: "USD")
    field(:warning_threshold, :integer, default: 80)
    field(:critical_threshold, :integer, default: 95)
    field(:current_month_spend, :decimal, default: Decimal.new("0"))
    field(:current_day_spend, :decimal, default: Decimal.new("0"))
    field(:projected_month_spend, :decimal)
    field(:start_date, :date)
    field(:end_date, :date)
    field(:is_active, :boolean, default: true)
    field(:last_alert_sent_at, :utc_datetime)
    field(:metadata, :map, default: %{})
    has_many(:alerts, BudgetAlert)
    timestamps()
  end

  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [
      :name,
      :description,
      :scope_type,
      :scope_value,
      :tags,
      :monthly_limit,
      :daily_limit,
      :currency,
      :warning_threshold,
      :critical_threshold,
      :current_month_spend,
      :current_day_spend,
      :projected_month_spend,
      :start_date,
      :end_date,
      :is_active,
      :last_alert_sent_at,
      :metadata
    ])
    |> validate_required([:name, :scope_type, :monthly_limit, :start_date])
    |> validate_inclusion(:scope_type, ["organization", "team", "project", "tag", "custom"])
    |> validate_number(:monthly_limit, greater_than: 0)
    |> validate_number(:warning_threshold, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:critical_threshold, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_thresholds()
  end

  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @spec update_spend(integer(), Decimal.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update_spend(budget_id, amount) do
    budget = Repo.get!(__MODULE__, budget_id)

    budget
    |> changeset(%{
      current_month_spend: Decimal.add(budget.current_month_spend, amount),
      current_day_spend: Decimal.add(budget.current_day_spend, amount)
    })
    |> Repo.update()
    |> case do
      {:ok, updated_budget} ->
        check_and_alert(updated_budget)
        {:ok, updated_budget}

      error ->
        error
    end
  end

  @spec check_and_alert(t()) :: :ok | {:error, term()}
  def check_and_alert(%__MODULE__{} = budget) do
    percent_used = calculate_percent_used(budget)

    cond do
      percent_used >= budget.critical_threshold ->
        create_alert(budget, "critical", percent_used)

      percent_used >= budget.warning_threshold ->
        create_alert(budget, "warning", percent_used)

      true ->
        :ok
    end
  end

  @spec exceeded_budgets() :: list(t())
  def exceeded_budgets do
    from(b in __MODULE__,
      where: b.is_active == true,
      where: b.current_month_spend > b.monthly_limit * 0.80
    )
    |> Repo.all()
  end

  @spec reset_daily_spend() :: {integer(), nil}
  def reset_daily_spend do
    from(b in __MODULE__, where: b.is_active == true)
    |> Repo.update_all(set: [current_day_spend: Decimal.new("0")])
  end

  @spec reset_monthly_spend() :: {integer(), nil}
  def reset_monthly_spend do
    from(b in __MODULE__, where: b.is_active == true)
    |> Repo.update_all(
      set: [
        current_month_spend: Decimal.new("0"),
        current_day_spend: Decimal.new("0")
      ]
    )
  end

  defp validate_thresholds(changeset) do
    warning = get_field(changeset, :warning_threshold)
    critical = get_field(changeset, :critical_threshold)

    if warning && critical && critical <= warning do
      add_error(changeset, :critical_threshold, "must be greater than warning threshold")
    else
      changeset
    end
  end

  defp calculate_percent_used(%__MODULE__{} = budget) do
    if Decimal.compare(budget.monthly_limit, Decimal.new("0")) == :gt do
      budget.current_month_spend
      |> Decimal.div(budget.monthly_limit)
      |> Decimal.mult(Decimal.new("100"))
      |> Decimal.to_float()
    else
      0.0
    end
  end

  defp create_alert(budget, severity, percent_used) do
    if should_create_alert?(budget) do
      BudgetAlert.create(%{
        budget_id: budget.id,
        alert_type: "threshold_exceeded",
        severity: severity,
        threshold_percent:
          if(severity == "critical",
            do: budget.critical_threshold,
            else: budget.warning_threshold
          ),
        current_spend: budget.current_month_spend,
        budget_limit: budget.monthly_limit,
        percent_used: percent_used,
        message: build_alert_message(budget, severity, percent_used)
      })

      budget
      |> changeset(%{last_alert_sent_at: DateTime.utc_now()})
      |> Repo.update()

      :ok
    else
      :ok
    end
  end

  defp should_create_alert?(%__MODULE__{last_alert_sent_at: nil}), do: true

  defp should_create_alert?(%__MODULE__{last_alert_sent_at: last_alert}) do
    DateTime.diff(DateTime.utc_now(), last_alert, :second) > 3600
  end

  defp build_alert_message(budget, severity, percent_used) do
    """
    Budget Alert: #{budget.name}
    Severity: #{String.upcase(severity)}
    Current Spend: #{budget.currency} #{Decimal.to_string(budget.current_month_spend, :normal)}
    Budget Limit: #{budget.currency} #{Decimal.to_string(budget.monthly_limit, :normal)}
    Used: #{Float.round(percent_used, 2)}%
    Scope: #{budget.scope_type}#{if budget.scope_value, do: " (#{budget.scope_value})", else: ""}
    """
  end
end
