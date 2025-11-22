defmodule Orchestrator.Metrics.DashboardPanel do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.Dashboard
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @panel_types ~w(graph stat gauge table heatmap logs)
  schema "dashboard_panels" do
    belongs_to(:dashboard, Dashboard, type: :binary_id)
    field(:title, :string)
    field(:description, :string)
    field(:type, :string)
    field(:query, :string)
    field(:datasource, :string, default: "default")
    field(:position, :map)
    field(:visualization, :map, default: %{})
    field(:thresholds, {:array, :map}, default: [])
    field(:refresh_interval, :integer)
    field(:time_range, :string)
    field(:variables, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(panel, attrs) do
    panel
    |> cast(attrs, [
      :dashboard_id,
      :title,
      :description,
      :type,
      :query,
      :datasource,
      :position,
      :visualization,
      :thresholds,
      :refresh_interval,
      :time_range,
      :variables
    ])
    |> validate_required([:title, :type, :query, :position])
    |> validate_inclusion(:type, @panel_types)
    |> validate_position()
    |> validate_visualization()
    |> foreign_key_constraint(:dashboard_id)
  end

  defp validate_position(changeset) do
    case get_field(changeset, :position) do
      %{"x" => x, "y" => y, "w" => w, "h" => h}
      when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h) ->
        cond do
          x < 0 or x >= 24 ->
            add_error(changeset, :position, "x must be 0-23")

          y < 0 ->
            add_error(changeset, :position, "y must be >= 0")

          w < 1 or w > 24 ->
            add_error(changeset, :position, "width must be 1-24")

          h < 1 ->
            add_error(changeset, :position, "height must be >= 1")

          true ->
            changeset
        end

      %{x: x, y: y, w: w, h: h}
      when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h) ->
        position = %{"x" => x, "y" => y, "w" => w, "h" => h}
        put_change(changeset, :position, position)

      _ ->
        add_error(changeset, :position, "must have x, y, w, h integer fields")
    end
  end

  defp validate_visualization(changeset) do
    vis = get_field(changeset, :visualization)

    if is_map(vis) do
      changeset
    else
      add_error(changeset, :visualization, "must be a map")
    end
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update(panel, attrs) do
    panel
    |> changeset(attrs)
    |> Repo.update()
  end

  def delete(panel) do
    Repo.delete(panel)
  end

  def list_for_dashboard(dashboard_id) do
    from(p in __MODULE__,
      where: p.dashboard_id == ^dashboard_id,
      order_by: [asc: fragment("position->>'y'"), asc: fragment("position->>'x'")]
    )
    |> Repo.all()
  end

  def reorder(positions) do
    Repo.transaction(fn ->
      Enum.each(positions, fn {panel_id, new_position} ->
        from(p in __MODULE__,
          where: p.id == ^panel_id
        )
        |> Repo.update_all(set: [position: new_position])
      end)
    end)
  end

  def duplicate(panel) do
    new_attrs = %{
      dashboard_id: panel.dashboard_id,
      title: "#{panel.title} (Copy)",
      description: panel.description,
      type: panel.type,
      query: panel.query,
      datasource: panel.datasource,
      position: shift_position_down(panel.position),
      visualization: panel.visualization,
      thresholds: panel.thresholds,
      refresh_interval: panel.refresh_interval,
      time_range: panel.time_range,
      variables: panel.variables
    }

    create(new_attrs)
  end

  defp shift_position_down(position) do
    %{position | "y" => position["y"] + (position["h"] || 8)}
  end
end
