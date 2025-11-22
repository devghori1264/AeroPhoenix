defmodule Orchestrator.FeatureFlags.ExperimentResult do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "experiment_results" do
    belongs_to(:experiment, Orchestrator.FeatureFlags.Experiment)
    field(:variation_key, :string)
    field(:metric_name, :string)
    field(:sample_size, :integer)
    field(:conversion_count, :integer)
    field(:conversion_rate, :decimal)
    field(:sum_of_values, :decimal)
    field(:mean, :decimal)
    field(:variance, :decimal)
    field(:std_dev, :decimal)
    field(:confidence_lower_bound, :decimal)
    field(:confidence_upper_bound, :decimal)
    field(:relative_improvement, :decimal)
    field(:p_value, :decimal)
    field(:is_significant, :boolean)
    field(:aggregation_period, :string)
    field(:period_start, :utc_datetime_usec)
    field(:period_end, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :experiment_id,
      :variation_key,
      :metric_name,
      :sample_size,
      :conversion_count,
      :conversion_rate,
      :sum_of_values,
      :mean,
      :variance,
      :std_dev,
      :confidence_lower_bound,
      :confidence_upper_bound,
      :relative_improvement,
      :p_value,
      :is_significant,
      :aggregation_period,
      :period_start,
      :period_end
    ])
    |> validate_required([:experiment_id, :variation_key, :metric_name])
    |> foreign_key_constraint(:experiment_id)
  end
end
