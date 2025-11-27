defmodule Orchestrator.Replication.PhiAccrualFailureDetector do
  require Logger

  @default_phi_threshold 8.0
  @default_sample_size 1000
  @default_min_std_deviation_ms 100
  @default_acceptable_heartbeat_pause_ms 10_000
  @heartbeat_dedup_window_ms 100

  @type phi_value :: float()
  @type timestamp_ms :: integer()

  @type t :: %__MODULE__{
          node_id: atom(),
          heartbeat_history: [timestamp_ms()],
          max_sample_size: pos_integer(),
          min_std_deviation_ms: pos_integer(),
          acceptable_heartbeat_pause_ms: pos_integer(),
          phi_threshold: float(),
          total_heartbeats: non_neg_integer(),
          last_heartbeat_at: timestamp_ms() | nil,
          created_at: DateTime.t()
        }

  defstruct node_id: nil,
            heartbeat_history: [],
            max_sample_size: @default_sample_size,
            min_std_deviation_ms: @default_min_std_deviation_ms,
            acceptable_heartbeat_pause_ms: @default_acceptable_heartbeat_pause_ms,
            phi_threshold: @default_phi_threshold,
            total_heartbeats: 0,
            last_heartbeat_at: nil,
            created_at: nil

  @spec init(atom(), keyword()) :: t()
  def init(node_id, opts \\ []) do
    %__MODULE__{
      node_id: node_id,
      phi_threshold: Keyword.get(opts, :phi_threshold, @default_phi_threshold),
      max_sample_size: Keyword.get(opts, :max_sample_size, @default_sample_size),
      min_std_deviation_ms:
        Keyword.get(opts, :min_std_deviation_ms, @default_min_std_deviation_ms),
      acceptable_heartbeat_pause_ms:
        Keyword.get(opts, :acceptable_heartbeat_pause_ms, @default_acceptable_heartbeat_pause_ms),
      created_at: DateTime.utc_now()
    }
  end

  @spec heartbeat(t()) :: t()
  def heartbeat(detector) do
    now = monotonic_time_ms()

    if detector.last_heartbeat_at != nil and
         now - detector.last_heartbeat_at < @heartbeat_dedup_window_ms do
      detector
    else
      updated_history =
        if detector.last_heartbeat_at != nil do
          interval = now - detector.last_heartbeat_at
          new_history = [interval | detector.heartbeat_history]

          Enum.take(new_history, detector.max_sample_size)
        else
          []
        end

      %{
        detector
        | heartbeat_history: updated_history,
          last_heartbeat_at: now,
          total_heartbeats: detector.total_heartbeats + 1
      }
    end
  end

  @spec phi(t()) :: {:ok, phi_value()} | {:insufficient_data, String.t()}
  def phi(detector) do
    cond do
      detector.last_heartbeat_at == nil ->
        {:insufficient_data, "no heartbeats received yet"}

      length(detector.heartbeat_history) < 1 ->
        {:insufficient_data, "need at least 2 heartbeats to calculate Φ"}

      true ->
        time_since_last = monotonic_time_ms() - detector.last_heartbeat_at
        phi_value = calculate_phi(detector.heartbeat_history, time_since_last, detector)
        {:ok, phi_value}
    end
  end

  @spec is_failed?(t()) :: boolean()
  def is_failed?(detector) do
    case phi(detector) do
      {:ok, phi_value} -> phi_value > detector.phi_threshold
      {:insufficient_data, _} -> false
    end
  end

  @spec suspicion_level(t()) :: :healthy | :warning | :suspect | :failed | :unknown
  def suspicion_level(detector) do
    case phi(detector) do
      {:ok, phi_value} ->
        cond do
          phi_value >= detector.phi_threshold -> :failed
          phi_value >= 3.0 -> :suspect
          phi_value >= 1.0 -> :warning
          true -> :healthy
        end

      {:insufficient_data, _} ->
        :unknown
    end
  end

  @spec stats(t()) :: map()
  def stats(detector) do
    {mean, std_dev} = calculate_statistics(detector.heartbeat_history, detector)

    time_since_last =
      if detector.last_heartbeat_at != nil do
        monotonic_time_ms() - detector.last_heartbeat_at
      else
        nil
      end

    phi_result = phi(detector)

    %{
      node_id: detector.node_id,
      phi:
        case phi_result do
          {:ok, val} -> Float.round(val, 2)
          {:insufficient_data, _} -> nil
        end,
      suspicion_level: suspicion_level(detector),
      total_heartbeats: detector.total_heartbeats,
      mean_interval_ms: if(mean, do: round(mean), else: nil),
      std_deviation_ms: if(std_dev, do: round(std_dev), else: nil),
      time_since_last_ms: time_since_last,
      sample_count: length(detector.heartbeat_history),
      phi_threshold: detector.phi_threshold
    }
  end

  @spec reset(t()) :: t()
  def reset(detector) do
    %{
      detector
      | heartbeat_history: [],
        last_heartbeat_at: nil,
        total_heartbeats: 0
    }
  end

  defp calculate_phi(intervals, time_since_last, detector) do
    {mean, std_dev} = calculate_statistics(intervals, detector)
    _ = std_dev

    if time_since_last > detector.acceptable_heartbeat_pause_ms do
      detector.phi_threshold * 2
    else
      safe_mean = max(mean, detector.min_std_deviation_ms)

      lambda = 1.0 / safe_mean
      probability = :math.exp(-lambda * time_since_last)

      if probability < 1.0e-16 do
        16.0
      else
        -:math.log10(probability)
      end
    end
  end

  defp calculate_statistics([], _detector) do
    {nil, nil}
  end

  defp calculate_statistics(intervals, detector) do
    mean = Enum.sum(intervals) / length(intervals)

    variance =
      intervals
      |> Enum.map(fn interval -> :math.pow(interval - mean, 2) end)
      |> Enum.sum()
      |> Kernel./(length(intervals))

    std_dev = :math.sqrt(variance)

    safe_std_dev = max(std_dev, detector.min_std_deviation_ms)

    {mean, safe_std_dev}
  end

  defp monotonic_time_ms do
    System.monotonic_time(:millisecond)
  end
end
