defmodule Orchestrator.FeatureFlags.Flag do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "feature_flags" do
    field(:key, :string)
    field(:name, :string)
    field(:description, :string)
    field(:status, Ecto.Enum, values: [:active, :inactive, :archived, :deprecated])
    field(:flag_type, Ecto.Enum, values: [:boolean, :string, :number, :json, :multivariate])
    field(:version, :integer)
    belongs_to(:previous_version, __MODULE__, type: :binary_id)
    field(:default_value_boolean, :boolean)
    field(:default_value_string, :string)
    field(:default_value_number, :decimal)
    field(:default_value_json, :map)

    field(:rollout_strategy, Ecto.Enum,
      values: [:all, :percentage, :user_list, :user_attribute, :segment, :gradual, :ring]
    )

    field(:rollout_percentage, :decimal)
    field(:gradual_rollout_config, :map)
    field(:owner, :string)
    field(:team, :string)
    field(:tags, {:array, :string})
    field(:metadata, :map)
    field(:enabled_at, :utc_datetime_usec)
    field(:disabled_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:requires_flags, {:array, :string})
    field(:conflicts_with_flags, {:array, :string})
    has_many(:targeting_rules, Orchestrator.FeatureFlags.TargetingRule)
    has_many(:overrides, Orchestrator.FeatureFlags.Override)
    has_many(:experiments, Orchestrator.FeatureFlags.Experiment)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(flag, attrs) do
    flag
    |> cast(attrs, [
      :key,
      :name,
      :description,
      :status,
      :flag_type,
      :default_value_boolean,
      :default_value_string,
      :default_value_number,
      :default_value_json,
      :rollout_strategy,
      :rollout_percentage,
      :gradual_rollout_config,
      :owner,
      :team,
      :tags,
      :metadata,
      :enabled_at,
      :disabled_at,
      :expires_at,
      :requires_flags,
      :conflicts_with_flags
    ])
    |> validate_required([:key, :name, :status, :flag_type])
    |> validate_format(:key, ~r/^[a-z0-9_]+$/,
      message: "must be lowercase alphanumeric with underscores"
    )
    |> validate_number(:rollout_percentage,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_default_value_for_type()
    |> unique_constraint(:key)
  end

  defp validate_default_value_for_type(changeset) do
    flag_type = get_field(changeset, :flag_type)

    case flag_type do
      :boolean -> validate_required(changeset, [:default_value_boolean])
      :string -> validate_required(changeset, [:default_value_string])
      :number -> validate_required(changeset, [:default_value_number])
      :json -> validate_required(changeset, [:default_value_json])
      :multivariate -> changeset
      _ -> changeset
    end
  end
end
