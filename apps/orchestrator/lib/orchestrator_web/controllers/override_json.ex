defmodule OrchestratorWeb.OverrideJSON do
  alias Orchestrator.FeatureFlags.Override

  def show(%{override: override}) do
    %{data: data(override)}
  end

  defp data(%Override{} = override) do
    %{
      id: override.id,
      flag_id: override.flag_id,
      flag_key: override.flag_key,
      user_id: override.user_id,
      machine_id: override.machine_id,
      segment_id: override.segment_id,
      override_value: override.override_value,
      enabled: override.enabled,
      expires_at: override.expires_at,
      created_by: override.created_by,
      reason: override.reason,
      inserted_at: override.inserted_at,
      updated_at: override.updated_at
    }
  end
end
