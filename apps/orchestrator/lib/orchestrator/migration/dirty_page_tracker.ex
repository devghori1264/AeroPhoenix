defmodule Orchestrator.Migration.DirtyPageTracker do
  use GenServer
  require Logger

  @type machine_id :: String.t()
  @type page_number :: non_neg_integer()
  @type dirty_page :: %{
          page_number: page_number(),
          offset: non_neg_integer(),
          length: non_neg_integer(),
          timestamp: DateTime.t(),
          checksum: String.t()
        }

  @page_size 4096
  @max_dirty_pages_per_iteration 100

  @spec start_tracking(machine_id()) :: :ok
  def start_tracking(machine_id) do
    GenServer.call(__MODULE__, {:start_tracking, machine_id})
  end

  @spec mark_dirty(machine_id(), non_neg_integer(), non_neg_integer()) :: :ok
  def mark_dirty(machine_id, offset, length) do
    GenServer.cast(__MODULE__, {:mark_dirty, machine_id, offset, length})
  end

  @spec get_dirty_pages(machine_id(), keyword()) :: list(dirty_page())
  def get_dirty_pages(machine_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_dirty_pages, machine_id, opts})
  end

  @spec clear_synced_pages(machine_id(), list(page_number())) :: :ok
  def clear_synced_pages(machine_id, page_numbers) do
    GenServer.call(__MODULE__, {:clear_synced_pages, machine_id, page_numbers})
  end

  @spec ready_for_cutover?(machine_id()) :: boolean()
  def ready_for_cutover?(machine_id) do
    GenServer.call(__MODULE__, {:ready_for_cutover?, machine_id})
  end

  @spec stop_tracking(machine_id()) :: :ok
  def stop_tracking(machine_id) do
    GenServer.call(__MODULE__, {:stop_tracking, machine_id})
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_tracking, machine_id}, _from, state) do
    Logger.info("Starting dirty page tracking", machine_id: machine_id)

    tracking_state = %{
      dirty_pages: %{},
      start_time: DateTime.utc_now(),
      total_writes: 0,
      total_pages_dirtied: 0
    }

    :telemetry.execute(
      [:orchestrator, :migration, :dirty_tracking_started],
      %{},
      %{machine_id: machine_id}
    )

    {:reply, :ok, Map.put(state, machine_id, tracking_state)}
  end

  @impl true
  def handle_call({:get_dirty_pages, machine_id, opts}, _from, state) do
    case Map.get(state, machine_id) do
      nil ->
        {:reply, [], state}

      tracking_state ->
        since = Keyword.get(opts, :since)
        limit = Keyword.get(opts, :limit)

        dirty_pages =
          tracking_state.dirty_pages
          |> Map.values()
          |> then(fn pages ->
            if since do
              Enum.filter(pages, fn page ->
                DateTime.compare(page.timestamp, since) == :gt
              end)
            else
              pages
            end
          end)
          |> Enum.sort_by(& &1.page_number)
          |> then(fn pages ->
            if limit, do: Enum.take(pages, limit), else: pages
          end)

        {:reply, dirty_pages, state}
    end
  end

  @impl true
  def handle_call({:clear_synced_pages, machine_id, page_numbers}, _from, state) do
    case Map.get(state, machine_id) do
      nil ->
        {:reply, :ok, state}

      tracking_state ->
        updated_dirty =
          Enum.reduce(page_numbers, tracking_state.dirty_pages, fn page_num, acc ->
            Map.delete(acc, page_num)
          end)

        updated_tracking = %{tracking_state | dirty_pages: updated_dirty}

        Logger.debug("Cleared synced pages",
          machine_id: machine_id,
          pages_cleared: length(page_numbers),
          remaining_dirty: map_size(updated_dirty)
        )

        {:reply, :ok, Map.put(state, machine_id, updated_tracking)}
    end
  end

  @impl true
  def handle_call({:ready_for_cutover?, machine_id}, _from, state) do
    ready =
      case Map.get(state, machine_id) do
        nil ->
          true

        tracking_state ->
          map_size(tracking_state.dirty_pages) < @max_dirty_pages_per_iteration
      end

    {:reply, ready, state}
  end

  @impl true
  def handle_call({:stop_tracking, machine_id}, _from, state) do
    Logger.info("Stopping dirty page tracking", machine_id: machine_id)

    case Map.get(state, machine_id) do
      nil ->
        {:reply, :ok, state}

      tracking_state ->
        :telemetry.execute(
          [:orchestrator, :migration, :dirty_tracking_stopped],
          %{
            total_writes: tracking_state.total_writes,
            total_pages_dirtied: tracking_state.total_pages_dirtied,
            final_dirty_count: map_size(tracking_state.dirty_pages)
          },
          %{machine_id: machine_id}
        )

        {:reply, :ok, Map.delete(state, machine_id)}
    end
  end

  @impl true
  def handle_cast({:mark_dirty, machine_id, offset, length}, state) do
    case Map.get(state, machine_id) do
      nil ->
        Logger.warning("Mark dirty called for untracked machine", machine_id: machine_id)
        {:noreply, state}

      tracking_state ->
        start_page = div(offset, @page_size)
        end_page = div(offset + length - 1, @page_size)

        updated_dirty =
          Enum.reduce(start_page..end_page, tracking_state.dirty_pages, fn page_num, acc ->
            page_offset = page_num * @page_size
            page_length = @page_size

            dirty_page = %{
              page_number: page_num,
              offset: page_offset,
              length: page_length,
              timestamp: DateTime.utc_now(),
              checksum: compute_page_checksum(machine_id, page_offset)
            }

            Map.put(acc, page_num, dirty_page)
          end)

        pages_dirtied = end_page - start_page + 1

        updated_tracking = %{
          tracking_state
          | dirty_pages: updated_dirty,
            total_writes: tracking_state.total_writes + 1,
            total_pages_dirtied: tracking_state.total_pages_dirtied + pages_dirtied
        }

        Logger.debug("Pages marked dirty",
          machine_id: machine_id,
          offset: offset,
          length: length,
          pages_affected: pages_dirtied,
          total_dirty: map_size(updated_dirty)
        )

        :telemetry.execute(
          [:orchestrator, :migration, :page_dirtied],
          %{pages_dirtied: pages_dirtied, total_dirty: map_size(updated_dirty)},
          %{machine_id: machine_id}
        )

        {:noreply, Map.put(state, machine_id, updated_tracking)}
    end
  end

  defp compute_page_checksum(_machine_id, _offset) do
    :crypto.hash(:sha256, :crypto.strong_rand_bytes(16))
    |> Base.encode16(case: :lower)
    |> String.slice(0..7)
  end
end
