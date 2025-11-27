defmodule Orchestrator.Scaling.ScalingPolicy do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "scaling_policies" do
    field(:service_name, :string)
    field(:strategy, Ecto.Enum, values: [:predictive, :reactive, :scheduled, :hybrid])
    field(:min_instances, :integer)
    field(:max_instances, :integer)
    field(:target_cpu_percent, :integer)
    field(:target_memory_percent, :integer)
    field(:target_request_rate, :integer)
    field(:scale_out_cooldown_seconds, :integer, default: 300)
    field(:scale_in_cooldown_seconds, :integer, default: 600)
    field(:scale_out_increment, :integer, default: 1)
    field(:scale_in_decrement, :integer, default: 1)
    field(:prediction_confidence_threshold, :float, default: 0.8)
    field(:enabled, :boolean, default: true)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :service_name,
      :strategy,
      :min_instances,
      :max_instances,
      :target_cpu_percent,
      :target_memory_percent,
      :target_request_rate,
      :scale_out_cooldown_seconds,
      :scale_in_cooldown_seconds,
      :scale_out_increment,
      :scale_in_decrement,
      :prediction_confidence_threshold,
      :enabled,
      :metadata
    ])
    |> validate_required([:service_name, :strategy, :min_instances, :max_instances])
    |> validate_number(:min_instances, greater_than: 0)
    |> validate_number(:max_instances, greater_than: 0)
    |> validate_number(:target_cpu_percent, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:target_memory_percent, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:prediction_confidence_threshold,
      greater_than: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> unique_constraint(:service_name)
    |> check_constraint(:max_instances,
      name: :max_greater_than_min,
      message: "must be greater than or equal to min_instances"
    )
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Orchestrator.Repo.insert()
  end

  def update(policy, attrs) do
    policy
    |> changeset(attrs)
    |> Orchestrator.Repo.update()
  end

  def list_enabled do
    import Ecto.Query
    Orchestrator.Repo.all(from(p in __MODULE__, where: p.enabled == true))
  end

  def get_by_service(service_name) do
    Orchestrator.Repo.get_by(__MODULE__, service_name: service_name)
  end
end
