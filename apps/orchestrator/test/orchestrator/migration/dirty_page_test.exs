defmodule Orchestrator.Migration.DirtyPageTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Migration.DirtyPageTracker
  alias Orchestrator.Migration.WriteBuffer
  alias Orchestrator.Migration.IncrementalSync
  alias Orchestrator.Migration.StateTransfer

  @moduletag :migration

  setup do
    start_supervised!(DirtyPageTracker)
    start_supervised!(WriteBuffer)
    start_supervised!(IncrementalSync)

    machine_id = "test_machine_#{:rand.uniform(100_000)}"

    on_exit(fn ->
      DirtyPageTracker.stop_tracking(machine_id)
      WriteBuffer.stop_buffering(machine_id)
    end)

    {:ok, machine_id: machine_id}
  end

  describe "DirtyPageTracker" do
    test "tracks single page write", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 100)

      dirty_pages = DirtyPageTracker.get_dirty_pages(machine_id)

      assert length(dirty_pages) == 1
      assert hd(dirty_pages).page_number == 0
      assert hd(dirty_pages).offset == 0
      assert hd(dirty_pages).length == 100
    end

    test "tracks multi-page write", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 4000, 6000)

      dirty_pages = DirtyPageTracker.get_dirty_pages(machine_id)

      assert length(dirty_pages) == 3

      page_numbers = Enum.map(dirty_pages, & &1.page_number) |> Enum.sort()
      assert page_numbers == [0, 1, 2]
    end

    test "deduplicates overlapping writes to same page", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 100)
      :ok = DirtyPageTracker.mark_dirty(machine_id, 100, 200)
      :ok = DirtyPageTracker.mark_dirty(machine_id, 500, 100)

      dirty_pages = DirtyPageTracker.get_dirty_pages(machine_id)

      assert length(dirty_pages) == 1
      assert hd(dirty_pages).page_number == 0
    end

    test "tracks writes to different pages", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 100)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 40_960, 100)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 409_600, 100)

      dirty_pages = DirtyPageTracker.get_dirty_pages(machine_id)

      assert length(dirty_pages) == 3

      page_numbers = Enum.map(dirty_pages, & &1.page_number) |> Enum.sort()
      assert page_numbers == [0, 10, 100]
    end

    test "supports incremental sync with timestamp filtering", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 100)
      :ok = DirtyPageTracker.mark_dirty(machine_id, 4096, 100)

      Process.sleep(10)
      checkpoint_time = DateTime.utc_now()
      Process.sleep(10)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 8192, 100)
      :ok = DirtyPageTracker.mark_dirty(machine_id, 12_288, 100)

      recent_dirty = DirtyPageTracker.get_dirty_pages(machine_id, since: checkpoint_time)

      page_numbers = Enum.map(recent_dirty, & &1.page_number) |> Enum.sort()
      assert page_numbers == [2, 3]

      all_dirty = DirtyPageTracker.get_dirty_pages(machine_id)
      assert length(all_dirty) == 4
    end

    test "clears synced pages from tracking", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 16_384)

      dirty_before = DirtyPageTracker.get_dirty_pages(machine_id)
      assert length(dirty_before) == 4

      :ok = DirtyPageTracker.clear_synced_pages(machine_id, [0, 1])

      dirty_after = DirtyPageTracker.get_dirty_pages(machine_id)
      assert length(dirty_after) == 2

      page_numbers = Enum.map(dirty_after, & &1.page_number) |> Enum.sort()
      assert page_numbers == [2, 3]
    end

    test "detects convergence when dirty set small", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 150 * 4096)

      refute DirtyPageTracker.ready_for_cutover?(machine_id)

      :ok = DirtyPageTracker.clear_synced_pages(machine_id, Enum.to_list(0..99))

      assert DirtyPageTracker.ready_for_cutover?(machine_id)
    end

    test "handles concurrent writes from multiple processes", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      tasks =
        for i <- 0..9 do
          Task.async(fn ->
            for j <- 0..9 do
              offset = (i * 10 + j) * 4096
              :ok = DirtyPageTracker.mark_dirty(machine_id, offset, 1000)
            end
          end)
        end

      Task.await_many(tasks, 5000)

      dirty_pages = DirtyPageTracker.get_dirty_pages(machine_id)

      assert length(dirty_pages) == 100
    end

    test "emits telemetry events", %{machine_id: machine_id} do
      events = [
        [:orchestrator, :migration, :dirty_tracking_started],
        [:orchestrator, :migration, :page_dirtied],
        [:orchestrator, :migration, :dirty_tracking_stopped]
      ]

      test_pid = self()

      :telemetry.attach_many(
        "test-handler",
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :ok = DirtyPageTracker.start_tracking(machine_id)
      assert_receive {:telemetry, [:orchestrator, :migration, :dirty_tracking_started], _, _}

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 100)
      assert_receive {:telemetry, [:orchestrator, :migration, :page_dirtied], measurements, _}
      assert measurements.total_dirty > 0

      :ok = DirtyPageTracker.stop_tracking(machine_id)

      assert_receive {:telemetry, [:orchestrator, :migration, :dirty_tracking_stopped],
                      measurements, _}

      assert measurements.total_writes > 0

      :telemetry.detach("test-handler")
    end
  end

  describe "WriteBuffer" do
    test "buffers write operations", %{machine_id: machine_id} do
      :ok = WriteBuffer.start_buffering(machine_id)

      data = "Hello, World!"
      :ok = WriteBuffer.buffer_write(machine_id, 0, data)

      writes = WriteBuffer.get_buffered_writes(machine_id)

      assert length(writes) == 1
      assert hd(writes).offset == 0
      assert hd(writes).data == data
    end

    test "maintains chronological order", %{machine_id: machine_id} do
      :ok = WriteBuffer.start_buffering(machine_id)

      :ok = WriteBuffer.buffer_write(machine_id, 0, "first")
      Process.sleep(5)
      :ok = WriteBuffer.buffer_write(machine_id, 100, "second")
      Process.sleep(5)
      :ok = WriteBuffer.buffer_write(machine_id, 200, "third")

      writes = WriteBuffer.get_buffered_writes(machine_id, coalesce: false)

      assert length(writes) == 3
      assert Enum.at(writes, 0).data == "first"
      assert Enum.at(writes, 1).data == "second"
      assert Enum.at(writes, 2).data == "third"
    end

    test "coalesces writes to same page", %{machine_id: machine_id} do
      :ok = WriteBuffer.start_buffering(machine_id)

      :ok = WriteBuffer.buffer_write(machine_id, 0, "write1")
      Process.sleep(5)
      :ok = WriteBuffer.buffer_write(machine_id, 100, "write2")
      Process.sleep(5)
      :ok = WriteBuffer.buffer_write(machine_id, 200, "write3")

      writes_uncoalesced = WriteBuffer.get_buffered_writes(machine_id, coalesce: false)
      assert length(writes_uncoalesced) == 3

      writes_coalesced = WriteBuffer.get_buffered_writes(machine_id, coalesce: true)
      assert length(writes_coalesced) == 1
      assert hd(writes_coalesced).data == "write3"
    end

    test "handles memory overflow to disk buffer", %{machine_id: machine_id} do
      :ok = WriteBuffer.start_buffering(machine_id)

      large_data = :crypto.strong_rand_bytes(12_000_000)
      :ok = WriteBuffer.buffer_write(machine_id, 0, large_data)

      stats = WriteBuffer.get_stats(machine_id)

      assert stats.overflow_writes > 0
      assert stats.overflow_bytes > 0
    end

    test "tracks buffer statistics", %{machine_id: machine_id} do
      :ok = WriteBuffer.start_buffering(machine_id)

      :ok = WriteBuffer.buffer_write(machine_id, 0, "test1")
      :ok = WriteBuffer.buffer_write(machine_id, 100, "test2")

      stats = WriteBuffer.get_stats(machine_id)

      assert stats.buffering == true
      assert stats.total_writes == 2
      assert stats.total_bytes == 10
      assert stats.memory_writes > 0
    end

    test "clears buffer after replay", %{machine_id: machine_id} do
      :ok = WriteBuffer.start_buffering(machine_id)

      :ok = WriteBuffer.buffer_write(machine_id, 0, "data")

      writes_before = WriteBuffer.get_buffered_writes(machine_id)
      assert length(writes_before) == 1

      :ok = WriteBuffer.clear_buffer(machine_id)

      writes_after = WriteBuffer.get_buffered_writes(machine_id)
      assert length(writes_after) == 0
    end
  end

  describe "IncrementalSync" do
    test "converges when dirty set shrinks", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 300 * 4096)

      spawn(fn ->
        Process.sleep(50)

        DirtyPageTracker.clear_synced_pages(machine_id, Enum.to_list(0..199))

        Process.sleep(1100)

        DirtyPageTracker.clear_synced_pages(machine_id, Enum.to_list(200..249))
      end)

      result =
        IncrementalSync.sync_until_convergence(
          machine_id,
          "destination_region",
          max_iterations: 5,
          convergence_threshold: 100
        )

      assert {:ready_for_cutover, stats} = result
      assert stats.iterations >= 1
      assert stats.final_dirty_pages < 100
    end

    test "detects non-convergence when dirty set grows", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 100 * 4096)

      task =
        Task.async(fn ->
          for i <- 1..10 do
            Process.sleep(1200)
            offset = (100 + i * 100) * 4096
            DirtyPageTracker.mark_dirty(machine_id, offset, 100 * 4096)
          end
        end)

      result =
        IncrementalSync.sync_until_convergence(
          machine_id,
          "destination_region",
          max_iterations: 5,
          convergence_threshold: 100
        )

      assert {:error, :non_convergence} = result

      Task.shutdown(task, :brutal_kill)
    end

    test "respects max iterations limit", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 500 * 4096)

      result =
        IncrementalSync.sync_until_convergence(
          machine_id,
          "destination_region",
          max_iterations: 3,
          convergence_threshold: 100
        )

      assert {:error, :max_iterations} = result
    end

    test "tracks progress during sync", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)
      :ok = DirtyPageTracker.mark_dirty(machine_id, 0, 200 * 4096)

      test_pid = self()

      task =
        Task.async(fn ->
          IncrementalSync.sync_until_convergence(
            machine_id,
            "destination_region",
            max_iterations: 5
          )
        end)

      Process.sleep(100)

      progress = IncrementalSync.get_progress(machine_id)

      if progress do
        assert is_integer(progress.iteration)
        assert progress.iteration >= 0
        assert is_number(progress.write_rate_estimate)
      end

      DirtyPageTracker.clear_synced_pages(machine_id, Enum.to_list(0..199))

      Task.await(task, 10_000)
    end
  end

  describe "Integration: Full Migration Flow" do
    test "complete live migration with dirty tracking", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)
      :ok = WriteBuffer.start_buffering(machine_id)

      for i <- 0..49 do
        offset = i * 4096
        data = "write_#{i}"
        :ok = DirtyPageTracker.mark_dirty(machine_id, offset, byte_size(data))
        :ok = WriteBuffer.buffer_write(machine_id, offset, data)
      end

      spawn(fn ->
        Process.sleep(50)
        DirtyPageTracker.clear_synced_pages(machine_id, Enum.to_list(0..40))

        Process.sleep(1100)
        DirtyPageTracker.clear_synced_pages(machine_id, Enum.to_list(41..49))
      end)

      result =
        IncrementalSync.sync_until_convergence(
          machine_id,
          "ord",
          convergence_threshold: 20
        )

      assert {:ready_for_cutover, stats} = result

      buffered_writes = WriteBuffer.get_buffered_writes(machine_id)
      assert length(buffered_writes) > 0

      :ok = WriteBuffer.clear_buffer(machine_id)
      :ok = DirtyPageTracker.stop_tracking(machine_id)
      :ok = WriteBuffer.stop_buffering(machine_id)
    end

    test "performance: track 10,000 dirty pages", %{machine_id: machine_id} do
      :ok = DirtyPageTracker.start_tracking(machine_id)

      start_time = System.monotonic_time(:millisecond)

      for i <- 0..9_999 do
        offset = i * 4096
        :ok = DirtyPageTracker.mark_dirty(machine_id, offset, 100)
      end

      mark_time = System.monotonic_time(:millisecond) - start_time

      retrieve_start = System.monotonic_time(:millisecond)
      dirty_pages = DirtyPageTracker.get_dirty_pages(machine_id)
      retrieve_time = System.monotonic_time(:millisecond) - retrieve_start

      assert length(dirty_pages) == 10_000

      assert mark_time < 5000
      assert retrieve_time < 1000

      IO.puts(
        "\nPerformance: Marked 10k pages in #{mark_time}ms, retrieved in #{retrieve_time}ms"
      )
    end
  end
end
