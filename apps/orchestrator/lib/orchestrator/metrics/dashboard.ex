defmodule Orchestrator.Metrics.Dashboard do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.DashboardPanel
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type time_range ::
          :last_5m | :last_15m | :last_1h | :last_6h | :last_24h | :last_7d | :last_30d
  @type refresh_interval :: 5 | 10 | 30 | 60 | 300 | 600 | 1800 | 3600
  schema "dashboards" do
    field(:name, :string)
    field(:description, :string)
    field(:tags, {:array, :string}, default: [])
    has_many(:panels, DashboardPanel, foreign_key: :dashboard_id)
    field(:time_range, :string, default: "1h")
    field(:refresh_interval, :integer, default: 30)
    field(:variables, :map, default: %{})
    field(:layout, :map, default: %{})
    field(:team, :string)
    field(:is_public, :boolean, default: false)
    field(:is_favorite, :boolean, default: false)
    field(:view_count, :integer, default: 0)
    field(:last_viewed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(dashboard, attrs) do
    dashboard
    |> cast(attrs, [
      :name,
      :description,
      :tags,
      :time_range,
      :refresh_interval,
      :variables,
      :layout,
      :team,
      :is_public,
      :is_favorite
    ])
    |> validate_required([:name])
    |> validate_time_range()
    |> validate_refresh_interval()
    |> validate_variables()
    |> unique_constraint([:name, :team])
  end

  defp validate_time_range(changeset) do
    validate_inclusion(changeset, :time_range, [
      "5m",
      "15m",
      "1h",
      "6h",
      "24h",
      "7d",
      "30d",
      "90d"
    ])
  end

  defp validate_refresh_interval(changeset) do
    validate_inclusion(changeset, :refresh_interval, [
      5,
      10,
      30,
      60,
      300,
      600,
      1800,
      3600
    ])
  end

  defp validate_variables(changeset) do
    case get_field(changeset, :variables) do
      vars when is_map(vars) ->
        valid? =
          Enum.all?(vars, fn {_key, var} ->
            is_map(var) and Map.has_key?(var, "type")
          end)

        if valid? do
          changeset
        else
          add_error(changeset, :variables, "must have type field")
        end

      _ ->
        changeset
    end
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update(dashboard, attrs) do
    dashboard
    |> changeset(attrs)
    |> Repo.update()
  end

  def delete(dashboard) do
    Repo.delete(dashboard)
  end

  def list_by_team(team) do
    from(d in __MODULE__,
      where: d.team == ^team or d.is_public == true,
      order_by: [desc: d.is_favorite, asc: d.name],
      preload: [:panels]
    )
    |> Repo.all()
  end

  def list_by_tag(tag) do
    from(d in __MODULE__,
      where: ^tag in d.tags,
      order_by: [desc: d.last_viewed_at],
      preload: [:panels]
    )
    |> Repo.all()
  end

  def favorites(team) do
    from(d in __MODULE__,
      where: d.team == ^team and d.is_favorite == true,
      order_by: [asc: d.name],
      preload: [:panels]
    )
    |> Repo.all()
  end

  def recently_viewed(team, limit \\ 10) do
    from(d in __MODULE__,
      where: d.team == ^team or d.is_public == true,
      where: not is_nil(d.last_viewed_at),
      order_by: [desc: d.last_viewed_at],
      limit: ^limit,
      preload: [:panels]
    )
    |> Repo.all()
  end

  def most_viewed(limit \\ 10) do
    from(d in __MODULE__,
      where: d.view_count > 0,
      order_by: [desc: d.view_count],
      limit: ^limit,
      preload: [:panels]
    )
    |> Repo.all()
  end

  def mark_favorite(dashboard) do
    dashboard
    |> change(is_favorite: true)
    |> Repo.update()
  end

  def unmark_favorite(dashboard) do
    dashboard
    |> change(is_favorite: false)
    |> Repo.update()
  end

  def record_view(dashboard) do
    dashboard
    |> change(
      view_count: dashboard.view_count + 1,
      last_viewed_at: DateTime.utc_now()
    )
    |> Repo.update()
  end

  def add_panel(dashboard, attrs) do
    attrs
    |> Map.put(:dashboard_id, dashboard.id)
    |> DashboardPanel.create()
  end

  def clone(dashboard, new_team) do
    Repo.transaction(fn ->
      new_attrs = %{
        name: "#{dashboard.name} (Copy)",
        description: dashboard.description,
        tags: dashboard.tags,
        time_range: dashboard.time_range,
        refresh_interval: dashboard.refresh_interval,
        variables: dashboard.variables,
        layout: dashboard.layout,
        team: new_team
      }

      {:ok, new_dashboard} = create(new_attrs)
      panels = Repo.preload(dashboard, :panels).panels

      Enum.each(panels, fn panel ->
        panel_attrs = %{
          dashboard_id: new_dashboard.id,
          title: panel.title,
          type: panel.type,
          query: panel.query,
          position: panel.position,
          visualization: panel.visualization,
          thresholds: panel.thresholds
        }

        DashboardPanel.create(panel_attrs)
      end)

      Repo.preload(new_dashboard, :panels, force: true)
    end)
  end

  def export(dashboard) do
    dashboard = Repo.preload(dashboard, :panels)

    %{
      name: dashboard.name,
      description: dashboard.description,
      tags: dashboard.tags,
      time_range: dashboard.time_range,
      refresh_interval: dashboard.refresh_interval,
      variables: dashboard.variables,
      layout: dashboard.layout,
      panels:
        Enum.map(dashboard.panels, fn panel ->
          %{
            title: panel.title,
            type: panel.type,
            query: panel.query,
            position: panel.position,
            visualization: panel.visualization,
            thresholds: panel.thresholds
          }
        end)
    }
  end

  def import(json, team) do
    Repo.transaction(fn ->
      {:ok, dashboard} =
        create(%{
          name: json["name"],
          description: json["description"],
          tags: json["tags"],
          time_range: json["time_range"],
          refresh_interval: json["refresh_interval"],
          variables: json["variables"],
          layout: json["layout"],
          team: team
        })

      Enum.each(json["panels"] || [], fn panel_json ->
        add_panel(dashboard, %{
          title: panel_json["title"],
          type: panel_json["type"],
          query: panel_json["query"],
          position: panel_json["position"],
          visualization: panel_json["visualization"],
          thresholds: panel_json["thresholds"]
        })
      end)

      Repo.preload(dashboard, :panels, force: true)
    end)
  end

  def search(query_string, team) do
    pattern = "%#{query_string}%"

    from(d in __MODULE__,
      where: d.team == ^team or d.is_public == true,
      where:
        ilike(d.name, ^pattern) or
          ilike(d.description, ^pattern),
      order_by: [desc: d.view_count],
      preload: [:panels]
    )
    |> Repo.all()
  end

  def stats do
    query = """
    SELECT
      COUNT(*) as total,
      COUNT(*) FILTER (WHERE is_public = true) as public_count,
      COUNT(*) FILTER (WHERE is_favorite = true) as favorite_count,
      AVG(view_count) as avg_views,
      COUNT(DISTINCT team) as team_count
    FROM dashboards
    """

    case Repo.query(query) do
      {:ok, %{rows: [[total, public, favorites, avg_views, teams]]}} ->
        {:ok,
         %{
           total: total,
           public: public,
           favorites: favorites,
           avg_views: Float.round(avg_views || 0.0, 2),
           teams: teams
         }}

      _ ->
        {:error, :query_failed}
    end
  end
end
