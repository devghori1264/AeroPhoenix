defmodule Orchestrator.Metrics.LatencyTracker do
  use GenServer
  require Logger

  @type metric_name :: String.t()
  @type latency_us :: non_neg_integer()
  @type percentile :: float()
  @type percentiles_map :: %{atom() => latency_us()}

  @lowest_trackable_value 1
  @highest_trackable_value 3_600_000_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(metric_name(), latency_us()) :: :ok
  def record(metric_name, latency_us) do
    GenServer.cast(__MODULE__, {:record, metric_name, latency_us})
  end

  @spec percentile(metric_name(), percentile()) :: {:ok, latency_us()} | {:error, :not_found}
  def percentile(metric_name, percentile) do
    GenServer.call(__MODULE__, {:percentile, metric_name, percentile})
  end

  @spec percentiles(metric_name(), [percentile()]) ::
          {:ok, percentiles_map()} | {:error, :not_found}
  def percentiles(metric_name, percentiles) do
    GenServer.call(__MODULE__, {:percentiles, metric_name, percentiles})
  end

  @spec windowed_percentiles(metric_name(), percentile()) :: {:ok, map()} | {:error, :not_found}
  def windowed_percentiles(metric_name, percentile) do
    GenServer.call(__MODULE__, {:windowed_percentiles, metric_name, percentile})
  end

  @spec reset(metric_name()) :: :ok
  def reset(metric_name) do
    GenServer.cast(__MODULE__, {:reset, metric_name})
  end

  @spec stats(metric_name()) :: {:ok, map()} | {:error, :not_found}
  def stats(metric_name) do
    GenServer.call(__MODULE__, {:stats, metric_name})
  end

  @impl true
  def init(_opts) do
    :ets.new(:latency_histograms, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:latency_windows, [:named_table, :set, :public])

    schedule_window_rotation()

    Logger.info("Latency Tracker started with HDR Histogram")

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, metric_name, latency_us}, state) do
    clamped_latency =
      latency_us
      |> max(@lowest_trackable_value)
      |> min(@highest_trackable_value)

    bucket_index = calculate_bucket_index(clamped_latency)

    :ets.update_counter(
      :latency_histograms,
      {metric_name, bucket_index},
      {2, 1},
      {{metric_name, bucket_index}, 0}
    )

    update_metadata(metric_name, clamped_latency)

    record_in_windows(metric_name, bucket_index)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:reset, metric_name}, state) do
    :ets.match_delete(:latency_histograms, {{metric_name, :_}, :_})
    :ets.delete(:latency_histograms, {metric_name, :metadata})
    :ets.match_delete(:latency_windows, {{metric_name, :_}, :_})

    Logger.debug("Latency Tracker: Reset histogram for #{metric_name}")

    {:noreply, state}
  end

  @impl true
  def handle_call({:percentile, metric_name, percentile}, _from, state) do
    result = calculate_percentile(metric_name, percentile)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:percentiles, metric_name, percentiles}, _from, state) do
    result = calculate_percentiles(metric_name, percentiles)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:windowed_percentiles, metric_name, percentile}, _from, state) do
    result = calculate_windowed_percentiles(metric_name, percentile)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:stats, metric_name}, _from, state) do
    result = get_stats(metric_name)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:rotate_windows, state) do
    rotate_all_windows()

    schedule_window_rotation()

    {:noreply, state}
  end

  defp calculate_bucket_index(value) do
    leading_zeros = count_leading_zeros(value)
    bucket_index = 64 - leading_zeros

    bucket_index
  end

  defp count_leading_zeros(0), do: 64

  defp count_leading_zeros(value) do
    do_count_leading_zeros(value, 0)
  end

  @sign_bit Bitwise.bsl(1, 63)

  defp do_count_leading_zeros(value, count) when value >= @sign_bit do
    count
  end

  defp do_count_leading_zeros(value, count) do
    do_count_leading_zeros(Bitwise.bsl(value, 1), count + 1)
  end

  defp update_metadata(metric_name, latency) do
    metadata_key = {metric_name, :metadata}

    case :ets.lookup(:latency_histograms, metadata_key) do
      [] ->
        :ets.insert(
          :latency_histograms,
          {metadata_key,
           %{
             count: 1,
             sum: latency,
             min: latency,
             max: latency
           }}
        )

      [{^metadata_key, metadata}] ->
        updated_metadata = %{
          count: metadata.count + 1,
          sum: metadata.sum + latency,
          min: min(metadata.min, latency),
          max: max(metadata.max, latency)
        }

        :ets.insert(:latency_histograms, {metadata_key, updated_metadata})
    end
  end

  defp record_in_windows(metric_name, bucket_index) do
    now = System.system_time(:second)

    :ets.update_counter(
      :latency_windows,
      {metric_name, :window_1min, bucket_index},
      {2, 1},
      {{metric_name, :window_1min, bucket_index}, 0}
    )

    :ets.update_counter(
      :latency_windows,
      {metric_name, :window_5min, bucket_index},
      {2, 1},
      {{metric_name, :window_5min, bucket_index}, 0}
    )

    :ets.update_counter(
      :latency_windows,
      {metric_name, :window_1hr, bucket_index},
      {2, 1},
      {{metric_name, :window_1hr, bucket_index}, 0}
    )

    :ets.insert(:latency_windows, {{metric_name, :last_update}, now})
  end

  defp calculate_percentile(metric_name, percentile) do
    metadata_key = {metric_name, :metadata}

    case :ets.lookup(:latency_histograms, metadata_key) do
      [] ->
        {:error, :not_found}

      [{^metadata_key, metadata}] ->
        total_count = metadata.count
        target_count = round(total_count * percentile / 100.0)

        buckets =
          :ets.match(:latency_histograms, {{metric_name, :"$1"}, :"$2"})
          |> Enum.filter(fn [index, _count] -> is_integer(index) end)
          |> Enum.sort_by(fn [index, _count] -> index end)

        result = find_percentile_bucket(buckets, target_count, 0)

        {:ok, result}
    end
  end

  defp find_percentile_bucket([], _target_count, _cumulative) do
    @highest_trackable_value
  end

  defp find_percentile_bucket([[bucket_index, count] | rest], target_count, cumulative) do
    new_cumulative = cumulative + count

    if new_cumulative >= target_count do
      bucket_index_to_value(bucket_index)
    else
      find_percentile_bucket(rest, target_count, new_cumulative)
    end
  end

  defp bucket_index_to_value(bucket_index) do
    Bitwise.bsl(1, bucket_index - 1)
  end

  defp calculate_percentiles(metric_name, percentiles) do
    results =
      Enum.map(percentiles, fn p ->
        case calculate_percentile(metric_name, p) do
          {:ok, value} ->
            key = percentile_to_atom(p)
            {key, value}

          {:error, _} ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    if map_size(results) == 0 do
      {:error, :not_found}
    else
      {:ok, results}
    end
  end

  defp calculate_windowed_percentiles(metric_name, percentile) do
    windows = [:window_1min, :window_5min, :window_1hr]

    results =
      Enum.map(windows, fn window ->
        value = calculate_window_percentile(metric_name, window, percentile)
        {window, value}
      end)
      |> Map.new()

    {:ok, results}
  end

  defp calculate_window_percentile(metric_name, window, percentile) do
    pattern = {{metric_name, window, :"$1"}, :"$2"}
    buckets = :ets.match(:latency_windows, pattern)

    if length(buckets) == 0 do
      0
    else
      total_count = Enum.reduce(buckets, 0, fn [_index, count], acc -> acc + count end)
      target_count = round(total_count * percentile / 100.0)

      sorted_buckets = Enum.sort_by(buckets, fn [index, _count] -> index end)
      find_percentile_bucket(sorted_buckets, target_count, 0)
    end
  end

  defp get_stats(metric_name) do
    metadata_key = {metric_name, :metadata}

    case :ets.lookup(:latency_histograms, metadata_key) do
      [] ->
        {:error, :not_found}

      [{^metadata_key, metadata}] ->
        mean = if metadata.count > 0, do: div(metadata.sum, metadata.count), else: 0

        stats = %{
          count: metadata.count,
          min: metadata.min,
          max: metadata.max,
          mean: mean,
          sum: metadata.sum
        }

        {:ok, stats}
    end
  end

  defp rotate_all_windows do
    :ok
  end

  defp schedule_window_rotation do
    Process.send_after(self(), :rotate_windows, 10_000)
  end

  defp percentile_to_atom(50.0), do: :p50
  defp percentile_to_atom(95.0), do: :p95
  defp percentile_to_atom(99.0), do: :p99
  defp percentile_to_atom(99.9), do: :p999
  defp percentile_to_atom(99.99), do: :p9999
  defp percentile_to_atom(p), do: String.to_atom("p#{trunc(p * 10)}")
end
