defmodule Orchestrator.FeatureFlags.Experiment do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "experiments" do
    belongs_to(:flag, Orchestrator.FeatureFlags.Flag)
    field(:key, :string)
    field(:name, :string)
    field(:description, :string)
    field(:hypothesis, :string)
    field(:status, Ecto.Enum, values: [:draft, :running, :paused, :completed, :winner_selected])
    field(:traffic_allocation, :decimal)
    field(:variations, {:array, :map})
    field(:primary_metric, :string)
    field(:secondary_metrics, {:array, :string})
    field(:minimum_sample_size, :integer)
    field(:confidence_level, :decimal)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:winning_variation, :string)
    field(:winner_selected_at, :utc_datetime_usec)
    field(:max_duration_days, :integer)
    field(:early_stopping_enabled, :boolean)
    field(:owner, :string)
    field(:team, :string)
    has_many(:results, Orchestrator.FeatureFlags.ExperimentResult)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(experiment, attrs) do
    experiment
    |> cast(attrs, [
      :flag_id,
      :key,
      :name,
      :description,
      :hypothesis,
      :status,
      :traffic_allocation,
      :variations,
      :primary_metric,
      :secondary_metrics,
      :minimum_sample_size,
      :confidence_level,
      :started_at,
      :ended_at,
      :winning_variation,
      :winner_selected_at,
      :max_duration_days,
      :early_stopping_enabled,
      :owner,
      :team
    ])
    |> validate_required([:flag_id, :key, :name, :variations, :primary_metric])
    |> validate_format(:key, ~r/^[a-z0-9_]+$/,
      message: "must be lowercase alphanumeric with underscores"
    )
    |> validate_number(:traffic_allocation,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:confidence_level,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_variations()
    |> unique_constraint(:key)
    |> foreign_key_constraint(:flag_id)
  end

  defp validate_variations(changeset) do
    variations = get_field(changeset, :variations)

    changeset
    |> validate_variations_format(variations)
    |> validate_variations_weights(variations)
  end

  defp validate_variations_format(changeset, variations) when is_list(variations) do
    if Enum.all?(variations, &valid_variation?/1) do
      changeset
    else
      add_error(changeset, :variations, "must have key, weight, and value fields")
    end
  end

  defp validate_variations_format(changeset, _), do: changeset

  defp valid_variation?(%{"key" => key, "weight" => weight, "value" => _value})
       when is_binary(key) and is_number(weight),
       do: true

  defp valid_variation?(_), do: false

  defp validate_variations_weights(changeset, variations) when is_list(variations) do
    total_weight =
      Enum.reduce(variations, 0, fn v, acc ->
        acc + (v["weight"] || 0)
      end)

    if total_weight == 100 do
      changeset
    else
      add_error(changeset, :variations, "weights must sum to 100, got #{total_weight}")
    end
  end

  defp validate_variations_weights(changeset, _), do: changeset
end
