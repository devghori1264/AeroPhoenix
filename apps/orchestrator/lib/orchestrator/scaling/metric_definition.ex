defmodule Orchestrator.Scaling.MetricDefinition do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "scaling_metric_definitions" do
    field(:name, :string)
    field(:type, Ecto.Enum, values: [:cpu, :memory, :request_rate, :latency, :custom])
    field(:unit, :string)
    field(:aggregation, Ecto.Enum, values: [:avg, :sum, :min, :max, :p95, :p99])
    field(:collection_interval_seconds, :integer, default: 60)
    field(:retention_days, :integer, default: 7)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :name,
      :type,
      :unit,
      :aggregation,
      :collection_interval_seconds,
      :retention_days,
      :metadata
    ])
    |> validate_required([:name, :type, :unit, :aggregation])
    |> unique_constraint(:name)
  end
end
