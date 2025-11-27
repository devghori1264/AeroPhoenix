defmodule Orchestrator.Migration.WriteBuffer do
  use GenServer
  require Logger

  @type machine_id :: String.t()
  @type write_op :: %{
          timestamp: DateTime.t(),
          offset: non_neg_integer(),
          length: non_neg_integer(),
          data: binary(),
          checksum: String.t()
        }

  @memory_buffer_size 10_485_760
  @overflow_batch_size 5_242_880

  @spec start_buffering(machine_id()) :: :ok
  def start_buffering(machine_id) do
    GenServer.call(__MODULE__, {:start_buffering, machine_id})
  end

  @spec buffer_write(machine_id(), non_neg_integer(), binary()) :: :ok
  def buffer_write(machine_id, offset, data) do
    GenServer.cast(__MODULE__, {:buffer_write, machine_id, offset, data})
  end

  @spec get_buffered_writes(machine_id(), keyword()) :: list(write_op())
  def get_buffered_writes(machine_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_buffered_writes, machine_id, opts})
  end

  @spec get_stats(machine_id()) :: map()
  def get_stats(machine_id) do
    GenServer.call(__MODULE__, {:get_stats, machine_id})
  end

  @spec clear_buffer(machine_id()) :: :ok
  def clear_buffer(machine_id) do
    GenServer.call(__MODULE__, {:clear_buffer, machine_id})
  end

  @spec stop_buffering(machine_id()) :: :ok
  def stop_buffering(machine_id) do
    GenServer.call(__MODULE__, {:stop_buffering, machine_id})
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_buffering, machine_id}, _from, state) do
    Logger.info("Starting write buffering", machine_id: machine_id)

    buffer_state = %{
      memory_buffer: [],
      memory_size: 0,
      overflow_buffer: [],
      overflow_size: 0,
      total_writes: 0,
      total_bytes: 0,
      start_time: DateTime.utc_now()
    }

    :telemetry.execute(
      [:orchestrator, :migration, :write_buffering_started],
      %{},
      %{machine_id: machine_id}
    )

    {:reply, :ok, Map.put(state, machine_id, buffer_state)}
  end

  @impl true
  def handle_call({:get_buffered_writes, machine_id, opts}, _from, state) do
    coalesce = Keyword.get(opts, :coalesce, true)
    limit = Keyword.get(opts, :limit)

    writes =
      case Map.get(state, machine_id) do
        nil ->
          []

        buffer_state ->
          all_writes = buffer_state.overflow_buffer ++ buffer_state.memory_buffer

          all_writes
          |> Enum.sort_by(& &1.timestamp, DateTime)
          |> then(fn writes ->
            if coalesce, do: coalesce_writes(writes), else: writes
          end)
          |> then(fn writes ->
            if limit, do: Enum.take(writes, limit), else: writes
          end)
      end

    {:reply, writes, state}
  end

  @impl true
  def handle_call({:get_stats, machine_id}, _from, state) do
    stats =
      case Map.get(state, machine_id) do
        nil ->
          %{buffering: false}

        buffer_state ->
          duration = DateTime.diff(DateTime.utc_now(), buffer_state.start_time, :second)

          %{
            buffering: true,
            memory_writes: length(buffer_state.memory_buffer),
            memory_bytes: buffer_state.memory_size,
            overflow_writes: length(buffer_state.overflow_buffer),
            overflow_bytes: buffer_state.overflow_size,
            total_writes: buffer_state.total_writes,
            total_bytes: buffer_state.total_bytes,
            duration_seconds: duration,
            write_rate_bps: if(duration > 0, do: buffer_state.total_bytes / duration, else: 0)
          }
      end

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:clear_buffer, machine_id}, _from, state) do
    case Map.get(state, machine_id) do
      nil ->
        {:reply, :ok, state}

      buffer_state ->
        cleared = %{
          buffer_state
          | memory_buffer: [],
            memory_size: 0,
            overflow_buffer: [],
            overflow_size: 0
        }

        Logger.info("Write buffer cleared",
          machine_id: machine_id,
          writes_cleared: buffer_state.total_writes
        )

        {:reply, :ok, Map.put(state, machine_id, cleared)}
    end
  end

  @impl true
  def handle_call({:stop_buffering, machine_id}, _from, state) do
    Logger.info("Stopping write buffering", machine_id: machine_id)

    case Map.get(state, machine_id) do
      nil ->
        {:reply, :ok, state}

      buffer_state ->
        :telemetry.execute(
          [:orchestrator, :migration, :write_buffering_stopped],
          %{
            total_writes: buffer_state.total_writes,
            total_bytes: buffer_state.total_bytes,
            memory_writes: length(buffer_state.memory_buffer),
            overflow_writes: length(buffer_state.overflow_buffer)
          },
          %{machine_id: machine_id}
        )

        {:reply, :ok, Map.delete(state, machine_id)}
    end
  end

  @impl true
  def handle_cast({:buffer_write, machine_id, offset, data}, state) do
    case Map.get(state, machine_id) do
      nil ->
        Logger.warning("Write buffered for untracked machine", machine_id: machine_id)
        {:noreply, state}

      buffer_state ->
        write_op = %{
          timestamp: DateTime.utc_now(),
          offset: offset,
          length: byte_size(data),
          data: data,
          checksum: compute_checksum(data)
        }

        new_memory_size = buffer_state.memory_size + byte_size(data)

        updated_buffer =
          if new_memory_size > @memory_buffer_size do
            {to_overflow, remaining, overflow_bytes} =
              flush_to_overflow_batched(buffer_state.memory_buffer, @overflow_batch_size)

            Logger.debug("Write buffer overflow",
              machine_id: machine_id,
              flushed_to_overflow: length(to_overflow),
              overflow_bytes: overflow_bytes,
              batch_size: @overflow_batch_size
            )

            :telemetry.execute(
              [:orchestrator, :migration, :write_buffer_overflow],
              %{flushed_count: length(to_overflow), flushed_bytes: overflow_bytes},
              %{machine_id: machine_id}
            )

            %{
              buffer_state
              | memory_buffer: remaining ++ [write_op],
                memory_size:
                  Enum.reduce(remaining, 0, fn w, acc -> acc + w.length end) + byte_size(data),
                overflow_buffer: buffer_state.overflow_buffer ++ to_overflow,
                overflow_size: buffer_state.overflow_size + overflow_bytes,
                total_writes: buffer_state.total_writes + 1,
                total_bytes: buffer_state.total_bytes + byte_size(data)
            }
          else
            %{
              buffer_state
              | memory_buffer: buffer_state.memory_buffer ++ [write_op],
                memory_size: new_memory_size,
                total_writes: buffer_state.total_writes + 1,
                total_bytes: buffer_state.total_bytes + byte_size(data)
            }
          end

        Logger.debug("Write buffered",
          machine_id: machine_id,
          offset: offset,
          length: byte_size(data),
          total_buffered: updated_buffer.total_writes
        )

        :telemetry.execute(
          [:orchestrator, :migration, :write_buffered],
          %{bytes: byte_size(data), total_writes: updated_buffer.total_writes},
          %{machine_id: machine_id}
        )

        {:noreply, Map.put(state, machine_id, updated_buffer)}
    end
  end

  defp flush_to_overflow_batched(memory_buffer, batch_size) do
    {to_flush, acc_size} =
      Enum.reduce_while(memory_buffer, {[], 0}, fn write, {acc, size} ->
        new_size = size + write.length

        if new_size >= batch_size do
          {:halt, {Enum.reverse([write | acc]), new_size}}
        else
          {:cont, {[write | acc], new_size}}
        end
      end)

    to_overflow = Enum.reverse(to_flush)
    remaining = Enum.drop(memory_buffer, length(to_overflow))
    {to_overflow, remaining, acc_size}
  end

  defp coalesce_writes(writes) do
    page_size = 4096

    writes
    |> Enum.group_by(fn w -> div(w.offset, page_size) end)
    |> Enum.map(fn {_page_num, page_writes} ->
      Enum.max_by(page_writes, & &1.timestamp, DateTime)
    end)
    |> Enum.sort_by(& &1.offset)
  end

  defp compute_checksum(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
    |> String.slice(0..7)
  end
end
