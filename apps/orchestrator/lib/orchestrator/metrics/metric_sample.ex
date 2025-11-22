defmodule Orchestrator.Metrics.MetricSample do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Metrics.MetricDefinition
  @primary_key false
  schema "metric_samples" do
    belongs_to(:metric, MetricDefinition, type: :binary_id)
    field(:timestamp, :utc_datetime_usec)
    field(:labels, :map, default: %{})
    field(:labels_hash, :string)
    field(:value, :float)
    field(:bucket_values, :map)
    field(:quantile_values, :map)
    field(:count, :integer)
    field(:sum, :float)
    field(:machine_id, :binary_id)
    field(:region, :string)
  end

  @doc false
  def changeset(sample, attrs) do
    sample
    |> cast(attrs, [
      :metric_id,
      :timestamp,
      :labels,
      :value,
      :bucket_values,
      :quantile_values,
      :count,
      :sum,
      :machine_id,
      :region
    ])
    |> validate_required([:metric_id, :timestamp])
    |> validate_value_or_distribution()
    |> put_labels_hash()
    |> put_default_timestamp()
  end

  defp validate_value_or_distribution(changeset) do
    value = get_field(changeset, :value)
    bucket_values = get_field(changeset, :bucket_values)

    if is_nil(value) and is_nil(bucket_values) do
      add_error(changeset, :value, "either value or bucket_values must be present")
    else
      changeset
    end
  end

  defp put_labels_hash(changeset) do
    case get_field(changeset, :labels) do
      nil ->
        put_change(changeset, :labels_hash, hash_labels(%{}))

      labels when is_map(labels) ->
        put_change(changeset, :labels_hash, hash_labels(labels))

      _ ->
        changeset
    end
  end

  defp put_default_timestamp(changeset) do
    if get_field(changeset, :timestamp) do
      changeset
    else
      put_change(changeset, :timestamp, DateTime.utc_now())
    end
  end

  defp hash_labels(labels) do
    labels
    |> Enum.sort()
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(",")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  def record(metric_id, attrs) do
    attrs = Map.put(attrs, :metric_id, metric_id)

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def record_batch(metric_id, samples) when is_list(samples) do
    now = DateTime.utc_now()

    entries =
      Enum.map(samples, fn attrs ->
        attrs
        |> Map.put(:metric_id, metric_id)
        |> Map.put_new(:timestamp, now)
        |> Map.update(:labels, %{}, &(&1 || %{}))
        |> then(fn attrs ->
          Map.put(attrs, :labels_hash, hash_labels(attrs.labels))
        end)
      end)

    Repo.insert_all(__MODULE__, entries)
  end

  def recent(metric_id, opts \\ []) do
    lookback = calculate_lookback(opts)
    limit = Keyword.get(opts, :limit, 1000)

    from(s in __MODULE__,
      where: s.metric_id == ^metric_id,
      where: s.timestamp >= ^lookback,
      order_by: [desc: s.timestamp],
      limit: ^limit
    )
    |> Repo.all()
  end

  def query(metric_id, label_filters, opts \\ []) do
    lookback = calculate_lookback(opts)
    limit = Keyword.get(opts, :limit, 1000)

    query =
      from(s in __MODULE__,
        where: s.metric_id == ^metric_id,
        where: s.timestamp >= ^lookback,
        order_by: [desc: s.timestamp],
        limit: ^limit
      )

    query =
      Enum.reduce(label_filters, query, fn {key, value}, q ->
        case value do
          values when is_list(values) ->
            Enum.reduce(values, q, fn v, acc ->
              from(s in acc,
                or_where: fragment("? @> ?", s.labels, ^%{key => v})
              )
            end)

          value ->
            from(s in q,
              where: fragment("? @> ?", s.labels, ^%{key => value})
            )
        end
      end)

    Repo.all(query)
  end

  def for_machine(machine_id, opts \\ []) do
    lookback = calculate_lookback(opts)
    limit = Keyword.get(opts, :limit, 1000)

    from(s in __MODULE__,
      where: s.machine_id == ^machine_id,
      where: s.timestamp >= ^lookback,
      order_by: [desc: s.timestamp],
      limit: ^limit
    )
    |> Repo.all()
  end

  def for_region(region, opts \\ []) do
    lookback = calculate_lookback(opts)
    limit = Keyword.get(opts, :limit, 1000)

    from(s in __MODULE__,
      where: s.region == ^region,
      where: s.timestamp >= ^lookback,
      order_by: [desc: s.timestamp],
      limit: ^limit
    )
    |> Repo.all()
  end

  def stats(metric_id, opts \\ []) do
    lookback = calculate_lookback(opts)

    from(s in __MODULE__,
      where: s.metric_id == ^metric_id,
      where: s.timestamp >= ^lookback,
      select: %{
        avg: avg(s.value),
        min: min(s.value),
        max: max(s.value),
        count: count(s.value),
        stddev: fragment("STDDEV(?)", s.value)
      }
    )
    |> Repo.one()
  end

  def percentiles(metric_id, opts \\ []) do
    lookback = calculate_lookback(opts)

    query = """
    SELECT
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY value) as p50,
      PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY value) as p90,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY value) as p95,
      PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY value) as p99
    FROM metric_samples
    WHERE metric_id = $1
      AND timestamp >= $2
    """

    case Repo.query(query, [metric_id, lookback]) do
      {:ok, %{rows: [[p50, p90, p95, p99]]}} ->
        {:ok, %{p50: p50, p90: p90, p95: p95, p99: p99}}

      _ ->
        {:error, :calculation_failed}
    end
  end

  def last_value(metric_id, label_filters \\ %{}) do
    query =
      from(s in __MODULE__,
        where: s.metric_id == ^metric_id,
        order_by: [desc: s.timestamp],
        limit: 1
      )

    query =
      if map_size(label_filters) > 0 do
        from(s in query,
          where: fragment("? @> ?", s.labels, ^label_filters)
        )
      else
        query
      end

    case Repo.one(query) do
      nil -> nil
      sample -> sample.value
    end
  end

  def rate(metric_id, opts \\ []) do
    lookback = calculate_lookback(opts)

    query = """
    WITH samples AS (
      SELECT value, timestamp
      FROM metric_samples
      WHERE metric_id = $1
        AND timestamp >= $2
      ORDER BY timestamp ASC
    ),
    first_sample AS (
      SELECT value as first_value, timestamp as first_time
      FROM samples
      LIMIT 1
    ),
    last_sample AS (
      SELECT value as last_value, timestamp as last_time
      FROM samples
      ORDER BY timestamp DESC
      LIMIT 1
    )
    SELECT
      (last_value - first_value) / EXTRACT(EPOCH FROM (last_time - first_time)) as rate
    FROM first_sample, last_sample
    WHERE last_time > first_time
    """

    case Repo.query(query, [metric_id, lookback]) do
      {:ok, %{rows: [[rate]]}} -> {:ok, rate}
      _ -> {:error, :insufficient_data}
    end
  end

  def delete_expired(metric_id, retention_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86400, :second)

    from(s in __MODULE__,
      where: s.metric_id == ^metric_id,
      where: s.timestamp < ^cutoff
    )
    |> Repo.delete_all()
  end

  defp calculate_lookback(opts) do
    cond do
      minutes = Keyword.get(opts, :minutes) ->
        DateTime.utc_now() |> DateTime.add(-minutes * 60, :second)

      hours = Keyword.get(opts, :hours) ->
        DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

      days = Keyword.get(opts, :days) ->
        DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

      true ->
        DateTime.utc_now() |> DateTime.add(-300, :second)
    end
  end
end
