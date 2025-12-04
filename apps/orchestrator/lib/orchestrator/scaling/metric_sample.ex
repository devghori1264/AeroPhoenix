defmodule Orchestrator.Scaling.MetricSample do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "scaling_metric_samples" do
    field(:service_name, :string)
    field(:metric_name, :string)
    field(:value, :float)
    field(:timestamp, :utc_datetime_usec)
    field(:tags, :map, default: %{})
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(sample, attrs) do
    sample
    |> cast(attrs, [:service_name, :metric_name, :value, :timestamp, :tags])
    |> validate_required([:service_name, :metric_name, :value, :timestamp])
  end
end
