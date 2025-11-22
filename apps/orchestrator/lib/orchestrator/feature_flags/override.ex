defmodule Orchestrator.FeatureFlags.Override do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "flag_overrides" do
    belongs_to(:flag, Orchestrator.FeatureFlags.Flag)
    field(:flag_key, :string)
    field(:user_id, :string)
    field(:machine_id, :string)
    field(:segment_id, :binary_id)
    field(:override_value, :map)
    field(:enabled, :boolean)
    field(:expires_at, :utc_datetime_usec)
    field(:created_by, :string)
    field(:reason, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [
      :flag_id,
      :flag_key,
      :user_id,
      :machine_id,
      :segment_id,
      :override_value,
      :enabled,
      :expires_at,
      :created_by,
      :reason
    ])
    |> validate_required([:flag_id, :override_value])
    |> validate_one_target_present()
    |> foreign_key_constraint(:flag_id)
  end

  defp validate_one_target_present(changeset) do
    user_id = get_field(changeset, :user_id)
    machine_id = get_field(changeset, :machine_id)
    segment_id = get_field(changeset, :segment_id)

    if is_nil(user_id) && is_nil(machine_id) && is_nil(segment_id) do
      add_error(
        changeset,
        :base,
        "must specify at least one target: user_id, machine_id, or segment_id"
      )
    else
      changeset
    end
  end
end
