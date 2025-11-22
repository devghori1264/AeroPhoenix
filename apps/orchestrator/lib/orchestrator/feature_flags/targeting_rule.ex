defmodule Orchestrator.FeatureFlags.TargetingRule do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "flag_targeting_rules" do
    belongs_to(:flag, Orchestrator.FeatureFlags.Flag)
    field(:priority, :integer)
    field(:enabled, :boolean)
    field(:name, :string)
    field(:description, :string)
    field(:conditions, {:array, :map})
    field(:variation_value_boolean, :boolean)
    field(:variation_value_string, :string)
    field(:variation_value_number, :decimal)
    field(:variation_value_json, :map)
    field(:rollout_percentage, :decimal)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :flag_id,
      :priority,
      :enabled,
      :name,
      :description,
      :conditions,
      :rollout_percentage,
      :variation_value_boolean,
      :variation_value_string,
      :variation_value_number,
      :variation_value_json
    ])
    |> validate_required([:flag_id, :conditions])
    |> validate_number(:rollout_percentage,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_conditions_format()
    |> foreign_key_constraint(:flag_id)
  end

  defp validate_conditions_format(changeset) do
    conditions = get_field(changeset, :conditions)

    if is_list(conditions) && Enum.all?(conditions, &valid_condition?/1) do
      changeset
    else
      add_error(changeset, :conditions, "must be a list of valid condition maps")
    end
  end

  defp valid_condition?(%{"attribute" => attr, "operator" => op, "value" => _val})
       when is_binary(attr) and is_binary(op),
       do: true

  defp valid_condition?(_), do: false
end
