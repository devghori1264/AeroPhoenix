defmodule Orchestrator.Cost.RightsizingRecommendation do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo

  @type t :: %__MODULE__{
          id: binary(),
          machine_id: binary(),
          region: String.t(),
          current_cpu: integer(),
          current_memory_mb: integer(),
          current_storage_gb: integer() | nil,
          recommended_cpu: integer(),
          recommended_memory_mb: integer(),
          recommended_storage_gb: integer() | nil,
          cpu_p95_utilization: float() | nil,
          memory_p95_utilization: float() | nil,
          analysis_period_days: integer(),
          current_monthly_cost: Decimal.t() | nil,
          recommended_monthly_cost: Decimal.t() | nil,
          monthly_savings: Decimal.t() | nil,
          annual_savings: Decimal.t() | nil,
          savings_percent: float() | nil,
          confidence_score: float() | nil,
          risk_level: String.t() | nil,
          status: String.t(),
          reason: String.t() | nil,
          approved_by: String.t() | nil,
          approved_at: DateTime.t() | nil,
          implemented_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "rightsizing_recommendations" do
    field(:machine_id, :binary_id)
    field(:region, :string)
    field(:current_cpu, :integer)
    field(:current_memory_mb, :integer)
    field(:current_storage_gb, :integer)
    field(:recommended_cpu, :integer)
    field(:recommended_memory_mb, :integer)
    field(:recommended_storage_gb, :integer)
    field(:cpu_p95_utilization, :float)
    field(:memory_p95_utilization, :float)
    field(:analysis_period_days, :integer, default: 7)
    field(:current_monthly_cost, :decimal)
    field(:recommended_monthly_cost, :decimal)
    field(:monthly_savings, :decimal)
    field(:annual_savings, :decimal)
    field(:savings_percent, :float)
    field(:confidence_score, :float)
    field(:risk_level, :string)
    field(:status, :string, default: "pending")
    field(:reason, :string)
    field(:approved_by, :string)
    field(:approved_at, :utc_datetime)
    field(:implemented_at, :utc_datetime)
    field(:expires_at, :utc_datetime)
    field(:metadata, :map, default: %{})
    timestamps()
  end

  def changeset(recommendation, attrs) do
    recommendation
    |> cast(attrs, [
      :machine_id,
      :region,
      :current_cpu,
      :current_memory_mb,
      :current_storage_gb,
      :recommended_cpu,
      :recommended_memory_mb,
      :recommended_storage_gb,
      :cpu_p95_utilization,
      :memory_p95_utilization,
      :analysis_period_days,
      :current_monthly_cost,
      :recommended_monthly_cost,
      :monthly_savings,
      :annual_savings,
      :savings_percent,
      :confidence_score,
      :risk_level,
      :status,
      :reason,
      :approved_by,
      :approved_at,
      :implemented_at,
      :expires_at,
      :metadata
    ])
    |> validate_required([
      :machine_id,
      :region,
      :current_cpu,
      :current_memory_mb,
      :recommended_cpu,
      :recommended_memory_mb
    ])
    |> validate_number(:current_cpu, greater_than: 0)
    |> validate_number(:recommended_cpu, greater_than: 0)
    |> validate_number(:current_memory_mb, greater_than: 0)
    |> validate_number(:recommended_memory_mb, greater_than: 0)
    |> validate_inclusion(:status, [
      "pending",
      "approved",
      "rejected",
      "implemented",
      "failed",
      "expired"
    ])
    |> validate_inclusion(:risk_level, ["low", "medium", "high"])
    |> put_default_expires_at()
  end

  @spec generate(binary(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def generate(machine_id, attrs) do
    attrs = Map.put(attrs, :machine_id, machine_id)

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @spec approve(binary(), String.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def approve(recommendation_id, approved_by) do
    Repo.get!(__MODULE__, recommendation_id)
    |> changeset(%{
      status: "approved",
      approved_by: approved_by,
      approved_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @spec mark_implemented(binary()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_implemented(recommendation_id) do
    Repo.get!(__MODULE__, recommendation_id)
    |> changeset(%{
      status: "implemented",
      implemented_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @spec pending_by_savings(keyword()) :: list(t())
  def pending_by_savings(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(r in __MODULE__,
      where: r.status == "pending",
      where: r.expires_at > ^DateTime.utc_now(),
      order_by: [desc: r.monthly_savings],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp put_default_expires_at(changeset) do
    if get_field(changeset, :expires_at) do
      changeset
    else
      expires_at = DateTime.utc_now() |> DateTime.add(30, :day)
      put_change(changeset, :expires_at, expires_at)
    end
  end
end
