defmodule OrchestratorWeb.FlagController do
  use OrchestratorWeb, :controller
  alias Orchestrator.FeatureFlags
  alias Orchestrator.FeatureFlags.Flag
  action_fallback(OrchestratorWeb.FallbackController)

  def index(conn, params) do
    filters = build_filters(params)
    flags = FeatureFlags.list_flags(filters)
    render(conn, :index, flags: flags)
  end

  def show(conn, %{"id" => id}) do
    case FeatureFlags.get_flag(id) do
      nil ->
        {:error, :not_found}

      flag ->
        flag = Orchestrator.Repo.preload(flag, [:targeting_rules, :overrides, :experiments])
        render(conn, :show, flag: flag)
    end
  end

  def create(conn, %{"flag" => flag_params}) do
    with {:ok, %Flag{} = flag} <- FeatureFlags.create_flag(flag_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/flags/#{flag.id}")
      |> render(:show, flag: flag)
    end
  end

  def update(conn, %{"id" => id, "flag" => flag_params}) do
    with flag when not is_nil(flag) <- FeatureFlags.get_flag(id),
         {:ok, %Flag{} = updated_flag} <- FeatureFlags.update_flag(flag, flag_params) do
      render(conn, :show, flag: updated_flag)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def delete(conn, %{"id" => id}) do
    with flag when not is_nil(flag) <- FeatureFlags.get_flag(id),
         {:ok, %Flag{}} <- FeatureFlags.delete_flag(flag) do
      send_resp(conn, :no_content, "")
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def enable(conn, %{"id" => id}) do
    with flag when not is_nil(flag) <- FeatureFlags.get_flag(id),
         {:ok, %Flag{} = updated_flag} <-
           FeatureFlags.update_flag(flag, %{
             status: :active,
             enabled_at: DateTime.utc_now()
           }) do
      render(conn, :show, flag: updated_flag)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def disable(conn, %{"id" => id}) do
    with flag when not is_nil(flag) <- FeatureFlags.get_flag(id),
         {:ok, %Flag{} = updated_flag} <-
           FeatureFlags.update_flag(flag, %{
             status: :inactive,
             disabled_at: DateTime.utc_now()
           }) do
      render(conn, :show, flag: updated_flag)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def evaluate(conn, %{"key" => key} = params) do
    context = %{
      user_id: params["user_id"],
      machine_id: params["machine_id"],
      session_id: params["session_id"],
      attributes: params["attributes"] || %{}
    }

    case FeatureFlags.evaluate(key, context) do
      {:ok, value} ->
        json(conn, %{
          flag_key: key,
          value: value,
          evaluated_at: DateTime.utc_now()
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  def evaluate_batch(conn, %{"flags" => flags, "context" => context_params}) do
    context = %{
      user_id: context_params["user_id"],
      machine_id: context_params["machine_id"],
      session_id: context_params["session_id"],
      attributes: context_params["attributes"] || %{}
    }

    results = FeatureFlags.evaluate_batch(flags, context)

    json(conn, %{
      flags: results,
      evaluated_at: DateTime.utc_now()
    })
  end

  def statistics(conn, %{"key" => key}) do
    case FeatureFlags.get_flag_statistics(key) do
      {:ok, stats} -> json(conn, %{flag_key: key, statistics: stats})
      error -> error
    end
  end

  defp build_filters(params) do
    []
    |> add_filter(:team, params["team"])
    |> add_filter(:owner, params["owner"])
    |> add_filter(:status, parse_status(params["status"]))
    |> add_filter(:tags, parse_tags(params["tags"]))
  end

  defp add_filter(filters, _key, nil), do: filters
  defp add_filter(filters, key, value), do: Keyword.put(filters, key, value)
  defp parse_status(nil), do: nil

  defp parse_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> nil
  end

  defp parse_tags(nil), do: nil

  defp parse_tags(tags) when is_binary(tags) do
    String.split(tags, ",", trim: true)
  end
end
