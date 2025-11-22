defmodule Orchestrator.FeatureFlags.Evaluation do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "flag_evaluations" do
    belongs_to(:flag, Orchestrator.FeatureFlags.Flag)
    field(:flag_key, :string)
    field(:user_id, :string)
    field(:machine_id, :string)
    field(:session_id, :string)
    field(:context, :map)
    field(:variation_key, :string)
    field(:variation_value, :map)
    field(:matched_rule_id, :binary_id)
    field(:reason, :string)
    field(:experiment_id, :binary_id)
    field(:in_experiment, :boolean)
    field(:evaluated_at, :utc_datetime_usec)
    field(:evaluation_duration_us, :integer)
  end
end
