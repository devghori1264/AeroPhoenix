defmodule Orchestrator.Replication.HybridLogicalClock do
  require Logger

  @max_drift_ms 60_000
  @max_logical_counter 1_000_000

  @type t :: %__MODULE__{
          physical_time: integer(),
          logical_counter: non_neg_integer(),
          node_id: atom()
        }

  defstruct [:physical_time, :logical_counter, :node_id]
  @spec init(keyword()) :: t()
  def init(opts \\ []) do
    node_id = Keyword.get(opts, :node_id, Node.self())

    %__MODULE__{
      physical_time: current_time_ms(),
      logical_counter: 0,
      node_id: node_id
    }
  end

  @spec tick(t()) :: t()
  def tick(hlc) do
    wall_time = current_time_ms()

    cond do
      wall_time > hlc.physical_time ->
        %{hlc | physical_time: wall_time, logical_counter: 0}

      wall_time == hlc.physical_time ->
        new_counter = hlc.logical_counter + 1

        if new_counter > @max_logical_counter do
          Logger.warning("HLC logical counter overflow, forcing physical time advance",
            node: hlc.node_id,
            counter: new_counter
          )

          %{hlc | physical_time: hlc.physical_time + 1, logical_counter: 0}
        else
          %{hlc | logical_counter: new_counter}
        end

      wall_time < hlc.physical_time ->
        drift = hlc.physical_time - wall_time

        if drift > @max_drift_ms do
          Logger.error("HLC drift exceeded maximum tolerance",
            node: hlc.node_id,
            drift_ms: drift,
            max_drift_ms: @max_drift_ms
          )
        end

        %{hlc | logical_counter: hlc.logical_counter + 1}
    end
  end

  @spec update(t(), t()) :: t()
  def update(local, remote) do
    wall_time = current_time_ms()

    max_pt = max(max(local.physical_time, remote.physical_time), wall_time)

    new_counter =
      cond do
        max_pt == local.physical_time and max_pt == remote.physical_time and
            max_pt == wall_time ->
          max(local.logical_counter, remote.logical_counter) + 1

        max_pt == local.physical_time and max_pt == remote.physical_time ->
          max(local.logical_counter, remote.logical_counter) + 1

        max_pt == local.physical_time ->
          local.logical_counter + 1

        max_pt == remote.physical_time ->
          remote.logical_counter + 1

        true ->
          0
      end

    if max_pt > wall_time do
      drift = max_pt - wall_time

      if drift > @max_drift_ms do
        Logger.warning("HLC ahead of wall clock by excessive amount",
          node: local.node_id,
          drift_ms: drift,
          local_pt: local.physical_time,
          remote_pt: remote.physical_time,
          wall_time: wall_time
        )
      end
    end

    %{local | physical_time: max_pt, logical_counter: new_counter}
  end

  @spec compare(t(), t()) :: :gt | :lt | :eq
  def compare(hlc1, hlc2) do
    cond do
      hlc1.physical_time > hlc2.physical_time -> :gt
      hlc1.physical_time < hlc2.physical_time -> :lt
      hlc1.logical_counter > hlc2.logical_counter -> :gt
      hlc1.logical_counter < hlc2.logical_counter -> :lt
      hlc1.node_id > hlc2.node_id -> :gt
      hlc1.node_id < hlc2.node_id -> :lt
      true -> :eq
    end
  end

  @spec to_datetime(t()) :: DateTime.t()
  def to_datetime(hlc) do
    DateTime.from_unix!(hlc.physical_time, :millisecond)
  end

  @spec to_timestamp(t()) :: {integer(), non_neg_integer()}
  def to_timestamp(hlc) do
    {hlc.physical_time, hlc.logical_counter}
  end

  @spec from_timestamp({integer(), non_neg_integer()}, atom()) :: t()
  def from_timestamp({physical_time, logical_counter}, node_id) do
    %__MODULE__{
      physical_time: physical_time,
      logical_counter: logical_counter,
      node_id: node_id
    }
  end

  @spec time_diff_ms(t(), t()) :: integer()
  def time_diff_ms(hlc1, hlc2) do
    hlc1.physical_time - hlc2.physical_time
  end

  defp current_time_ms do
    System.system_time(:millisecond)
  end
end
