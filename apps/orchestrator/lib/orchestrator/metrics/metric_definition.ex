defmodule Orchestrator.Metrics.MetricDefinition do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type metric_type :: :counter | :gauge | :histogram | :summary
  @type metric_unit ::
          :none
          | :percent
          | :bytes
          | :milliseconds
          | :seconds
          | :requests_per_sec
          | :ops_per_sec
  schema "metric_definitions" do
    field(:name, :string)
    field(:type, Ecto.Enum, values: [:counter, :gauge, :histogram, :summary])

    field(:unit, Ecto.Enum,
      values: [:none, :percent, :bytes, :milliseconds, :seconds, :requests_per_sec, :ops_per_sec]
    )

    field(:help, :string)
    field(:namespace, :string)
    field(:subsystem, :string)
    field(:label_keys, {:array, :string}, default: [])
    field(:cardinality, :integer, default: 0)
    field(:retention_days, :integer, default: 90)
    field(:compression_enabled, :boolean, default: true)
    field(:compress_after_hours, :integer, default: 1)
    field(:enabled, :boolean, default: true)
    field(:created_by, :binary_id)
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(metric, attrs) do
    metric
    |> cast(attrs, [
      :name,
      :type,
      :unit,
      :help,
      :namespace,
      :subsystem,
      :label_keys,
      :retention_days,
      :compression_enabled,
      :compress_after_hours,
      :enabled,
      :created_by
    ])
    |> validate_required([:name, :type, :unit])
    |> validate_metric_name()
    |> validate_label_keys()
    |> validate_retention()
    |> unique_constraint(:name)
  end

  defp validate_metric_name(changeset) do
    changeset
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with lowercase letter and contain only lowercase, digits, and underscores"
    )
    |> validate_length(:name, min: 3, max: 100)
  end

  defp validate_label_keys(changeset) do
    case get_field(changeset, :label_keys) do
      nil ->
        changeset

      keys ->
        if Enum.all?(keys, &valid_label_key?/1) do
          changeset
        else
          add_error(
            changeset,
            :label_keys,
            "must contain only lowercase, digits, and underscores"
          )
        end
    end
  end

  defp valid_label_key?(key) do
    Regex.match?(~r/^[a-z][a-z0-9_]*$/, key)
  end

  defp validate_retention(changeset) do
    changeset
    |> validate_number(:retention_days, greater_than: 0, less_than_or_equal_to: 3650)
    |> validate_number(:compress_after_hours, greater_than: 0, less_than_or_equal_to: 168)
  end

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update(metric, attrs) do
    metric
    |> changeset(attrs)
    |> Repo.update()
  end

  def get_by_name(name) do
    Repo.get_by(__MODULE__, name: name)
  end

  def list_enabled do
    from(m in __MODULE__, where: m.enabled == true, order_by: [asc: m.namespace, asc: m.name])
    |> Repo.all()
  end

  def list_by_namespace(namespace, subsystem \\ nil) do
    query = from(m in __MODULE__, where: m.namespace == ^namespace)

    query =
      if subsystem do
        from(m in query, where: m.subsystem == ^subsystem)
      else
        query
      end

    Repo.all(query)
  end

  def high_cardinality_metrics(threshold \\ 100_000) do
    from(m in __MODULE__,
      where: m.cardinality > ^threshold,
      order_by: [desc: m.cardinality]
    )
    |> Repo.all()
  end

  def disable(metric) do
    metric
    |> change(enabled: false)
    |> Repo.update()
  end

  def enable(metric) do
    metric
    |> change(enabled: true)
    |> Repo.update()
  end
end
