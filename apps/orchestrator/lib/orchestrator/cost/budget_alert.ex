defmodule Orchestrator.Cost.BudgetAlert do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Cost.Budget

  @type t :: %__MODULE__{
          id: binary(),
          budget_id: integer(),
          alert_type: String.t(),
          severity: String.t(),
          threshold_percent: integer(),
          current_spend: Decimal.t(),
          budget_limit: Decimal.t(),
          percent_used: float(),
          projected_spend: Decimal.t() | nil,
          projected_overage: Decimal.t() | nil,
          days_until_exceeded: integer() | nil,
          notified_at: DateTime.t() | nil,
          notification_channels: list(String.t()),
          acknowledged_at: DateTime.t() | nil,
          acknowledged_by: String.t() | nil,
          message: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t()
        }
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "budget_alerts" do
    belongs_to(:budget, Budget)
    field(:alert_type, :string)
    field(:severity, :string)
    field(:threshold_percent, :integer)
    field(:current_spend, :decimal)
    field(:budget_limit, :decimal)
    field(:percent_used, :float)
    field(:projected_spend, :decimal)
    field(:projected_overage, :decimal)
    field(:days_until_exceeded, :integer)
    field(:notified_at, :utc_datetime)
    field(:notification_channels, {:array, :string}, default: [])
    field(:acknowledged_at, :utc_datetime)
    field(:acknowledged_by, :string)
    field(:message, :string)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(alert, attrs) do
    alert
    |> cast(attrs, [
      :budget_id,
      :alert_type,
      :severity,
      :threshold_percent,
      :current_spend,
      :budget_limit,
      :percent_used,
      :projected_spend,
      :projected_overage,
      :days_until_exceeded,
      :notified_at,
      :notification_channels,
      :acknowledged_at,
      :acknowledged_by,
      :message,
      :metadata
    ])
    |> validate_required([
      :budget_id,
      :alert_type,
      :severity,
      :threshold_percent,
      :current_spend,
      :budget_limit,
      :percent_used
    ])
    |> validate_inclusion(:severity, ["info", "warning", "critical"])
    |> foreign_key_constraint(:budget_id)
  end

  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @spec acknowledge(binary(), String.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def acknowledge(alert_id, acknowledged_by) do
    Repo.get!(__MODULE__, alert_id)
    |> changeset(%{
      acknowledged_at: DateTime.utc_now(),
      acknowledged_by: acknowledged_by
    })
    |> Repo.update()
  end

  @spec unacknowledged(keyword()) :: list(t())
  def unacknowledged(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(a in __MODULE__,
      where: is_nil(a.acknowledged_at),
      order_by: [desc: a.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end
