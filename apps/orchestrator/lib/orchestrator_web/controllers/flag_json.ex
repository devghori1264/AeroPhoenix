defmodule OrchestratorWeb.FlagJSON do
  alias Orchestrator.FeatureFlags.Flag

  def index(%{flags: flags}) do
    %{data: for(flag <- flags, do: data(flag))}
  end

  def show(%{flag: flag}) do
    %{data: data(flag)}
  end

  defp data(%Flag{} = flag) do
    %{
      id: flag.id,
      key: flag.key,
      name: flag.name,
      description: flag.description,
      status: flag.status,
      flag_type: flag.flag_type,
      version: flag.version,
      default_value: get_default_value(flag),
      rollout_strategy: flag.rollout_strategy,
      rollout_percentage: flag.rollout_percentage,
      gradual_rollout_config: flag.gradual_rollout_config,
      owner: flag.owner,
      team: flag.team,
      tags: flag.tags,
      metadata: flag.metadata,
      enabled_at: flag.enabled_at,
      disabled_at: flag.disabled_at,
      expires_at: flag.expires_at,
      requires_flags: flag.requires_flags,
      conflicts_with_flags: flag.conflicts_with_flags,
      targeting_rules: render_targeting_rules(flag),
      overrides: render_overrides(flag),
      experiments: render_experiments(flag),
      inserted_at: flag.inserted_at,
      updated_at: flag.updated_at
    }
  end

  defp get_default_value(flag) do
    case flag.flag_type do
      :boolean -> flag.default_value_boolean
      :string -> flag.default_value_string
      :number -> flag.default_value_number
      :json -> flag.default_value_json
      :multivariate -> nil
      _ -> nil
    end
  end

  defp render_targeting_rules(%{targeting_rules: %Ecto.Association.NotLoaded{}}), do: nil

  defp render_targeting_rules(%{targeting_rules: rules}) when is_list(rules) do
    Enum.map(rules, fn rule ->
      %{
        id: rule.id,
        priority: rule.priority,
        enabled: rule.enabled,
        name: rule.name,
        conditions: rule.conditions,
        variation_value: get_variation_value(rule),
        rollout_percentage: rule.rollout_percentage
      }
    end)
  end

  defp render_targeting_rules(_), do: nil

  defp get_variation_value(rule) do
    cond do
      rule.variation_value_boolean != nil -> rule.variation_value_boolean
      rule.variation_value_string != nil -> rule.variation_value_string
      rule.variation_value_number != nil -> rule.variation_value_number
      rule.variation_value_json != nil -> rule.variation_value_json
      true -> nil
    end
  end

  defp render_overrides(%{overrides: %Ecto.Association.NotLoaded{}}), do: nil

  defp render_overrides(%{overrides: overrides}) when is_list(overrides) do
    Enum.map(overrides, fn override ->
      %{
        id: override.id,
        user_id: override.user_id,
        machine_id: override.machine_id,
        override_value: override.override_value,
        expires_at: override.expires_at
      }
    end)
  end

  defp render_overrides(_), do: nil
  defp render_experiments(%{experiments: %Ecto.Association.NotLoaded{}}), do: nil

  defp render_experiments(%{experiments: experiments}) when is_list(experiments) do
    Enum.map(experiments, fn experiment ->
      %{
        id: experiment.id,
        key: experiment.key,
        name: experiment.name,
        status: experiment.status
      }
    end)
  end

  defp render_experiments(_), do: nil
end
