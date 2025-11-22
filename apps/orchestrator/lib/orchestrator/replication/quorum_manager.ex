defmodule Orchestrator.Replication.QuorumManager do
  require Logger
  alias Orchestrator.Replication.CRDT.VectorClock
  @type consistency_level :: :strong | :eventual | :causal
  @type quorum_result :: {:ok, term()} | {:error, :quorum_not_met}
  defmodule Config do
    @moduledoc false
    defstruct [
      :read_quorum,
      :write_quorum,
      :total_replicas,
      :timeout
    ]
  end

  def read(key, replicas, opts \\ []) do
    consistency = Keyword.get(opts, :consistency, :strong)
    timeout = Keyword.get(opts, :timeout, 5_000)
    config = build_config(length(replicas), consistency)

    tasks =
      Enum.map(replicas, fn replica ->
        Task.async(fn ->
          read_from_replica(replica, key, timeout)
        end)
      end)

    responses = await_quorum_responses(tasks, config.read_quorum, timeout)

    case responses do
      {:ok, values} ->
        resolve_read(values, consistency)

      {:error, _} = error ->
        error
    end
  end

  def write(key, value, replicas, opts \\ []) do
    consistency = Keyword.get(opts, :consistency, :strong)
    timeout = Keyword.get(opts, :timeout, 5_000)
    vector_clock = Keyword.get(opts, :vector_clock, VectorClock.new())
    config = build_config(length(replicas), consistency)

    tasks =
      Enum.map(replicas, fn replica ->
        Task.async(fn ->
          write_to_replica(replica, key, value, vector_clock, timeout)
        end)
      end)

    responses = await_quorum_responses(tasks, config.write_quorum, timeout)

    case responses do
      {:ok, acks} ->
        {:ok, length(acks)}

      {:error, _} = error ->
        error
    end
  end

  def can_achieve_quorum?(available_replicas, total_replicas, consistency) do
    config = build_config(total_replicas, consistency)

    available_replicas >= config.read_quorum and
      available_replicas >= config.write_quorum
  end

  def quorum_sizes(total_replicas, consistency) do
    config = build_config(total_replicas, consistency)
    {config.read_quorum, config.write_quorum}
  end

  defp build_config(total_replicas, consistency) do
    {read_q, write_q} =
      case consistency do
        :strong ->
          majority = div(total_replicas, 2) + 1
          {majority, majority}

        :eventual ->
          {1, 1}

        :causal ->
          {div(total_replicas, 2) + 1, 1}
      end

    %Config{
      read_quorum: read_q,
      write_quorum: write_q,
      total_replicas: total_replicas,
      timeout: 5_000
    }
  end

  defp read_from_replica(replica, key, timeout) do
    try do
      :timer.sleep(:rand.uniform(50))

      {:ok,
       %{
         value: "value_for_#{key}_from_#{replica}",
         version: :rand.uniform(10),
         timestamp: System.system_time(:millisecond),
         replica: replica
       }}
    catch
      :exit, _ -> {:error, :timeout}
    end
  end

  defp write_to_replica(replica, key, value, vector_clock, timeout) do
    try do
      :timer.sleep(:rand.uniform(50))

      {:ok,
       %{
         replica: replica,
         key: key,
         value: value,
         vector_clock: vector_clock,
         ack: true
       }}
    catch
      :exit, _ -> {:error, :timeout}
    end
  end

  defp await_quorum_responses(tasks, quorum_size, timeout) do
    start_time = System.monotonic_time(:millisecond)
    collect_responses(tasks, quorum_size, [], timeout, start_time)
  end

  defp collect_responses(remaining_tasks, quorum_size, collected, timeout, start_time) do
    if length(collected) >= quorum_size do
      {:ok, collected}
    else
      elapsed = System.monotonic_time(:millisecond) - start_time

      if elapsed >= timeout or remaining_tasks == [] do
        {:error, :quorum_not_met}
      else
        case Task.yield_many(remaining_tasks, timeout - elapsed) do
          [] ->
            {:error, :quorum_not_met}

          results ->
            {completed, still_running} =
              Enum.split_with(results, fn {_task, result} -> result != nil end)

            new_collected =
              Enum.reduce(completed, collected, fn {_task, result}, acc ->
                case result do
                  {:ok, {:ok, value}} -> [value | acc]
                  _ -> acc
                end
              end)

            new_remaining = Enum.map(still_running, fn {task, _} -> task end)

            collect_responses(
              new_remaining,
              quorum_size,
              new_collected,
              timeout,
              start_time
            )
        end
      end
    end
  end

  defp resolve_read(values, :strong) do
    latest =
      values
      |> Enum.max_by(fn v -> v.version end, fn -> nil end)

    if latest do
      {:ok, latest.value}
    else
      {:error, :no_values}
    end
  end

  defp resolve_read(values, :eventual) do
    case List.first(values) do
      nil -> {:error, :no_values}
      value -> {:ok, value.value}
    end
  end

  defp resolve_read(values, :causal) do
    resolve_read(values, :strong)
  end
end
