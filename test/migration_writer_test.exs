defmodule PState.MigrationWriterTest do
  use ExUnit.Case, async: false

  alias PState.MigrationWriter

  # Test schema with migrations
  defmodule TestSchema do
    use PState.Schema

    entity :base_card do
      field(:id, :string)
      field(:front, :string)
      field(:back, :string)

      field :metadata, :map do
        migrate(fn
          str when is_binary(str) -> %{notes: str}
          map when is_map(map) -> map
        end)
      end
    end
  end

  # Helper to create PState with ETS adapter
  defp create_pstate(opts \\ []) do
    schema = Keyword.get(opts, :schema, nil)
    table_name = :"test_table_#{:erlang.unique_integer([:positive])}"

    pstate =
      PState.new("root:test",
        adapter: PState.Adapters.ETS,
        adapter_opts: [table_name: table_name],
        schema: schema
      )

    # Store initial data if provided
    data = Keyword.get(opts, :data, %{})

    Enum.reduce(data, pstate, fn {key, value}, acc ->
      put_in(acc[key], value)
    end)
  end

  setup do
    # Create a test PState instance
    pstate = create_pstate()

    # Start MigrationWriter
    {:ok, pid} = MigrationWriter.start_link(pstate: pstate, flush_interval: 100)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    {:ok, pstate: pstate, writer_pid: pid}
  end

  # RMX004_1A_T1: Test MigrationWriter starts
  test "RMX004_1A_T1: MigrationWriter starts successfully", %{writer_pid: pid} do
    assert Process.alive?(pid)
  end

  # RMX004_1A_T2: Test queue_write adds to queue
  test "RMX004_1A_T2: queue_write adds to queue" do
    # This test verifies async queueing works
    :ok = MigrationWriter.queue_write("base_card:test1", %{id: "test1", front: "Hello"})

    # Flush to verify it was queued
    :ok = MigrationWriter.flush()
  end

  # RMX004_1A_T3: Test auto-flush on batch_size
  test "RMX004_1A_T3: auto-flush triggers when batch_size reached" do
    pstate = create_pstate()

    # Stop default writer
    GenServer.stop(MigrationWriter)

    # Start with small batch size
    {:ok, _pid} =
      MigrationWriter.start_link(pstate: pstate, batch_size: 3, flush_interval: 10_000)

    # Queue 3 items (should trigger auto-flush)
    MigrationWriter.queue_write("key1", %{data: 1})
    MigrationWriter.queue_write("key2", %{data: 2})
    MigrationWriter.queue_write("key3", %{data: 3})

    # Give it a moment to flush
    Process.sleep(50)

    # Verify data was written
    assert {:ok, %{data: 1}} = pstate.adapter.get(pstate.adapter_state, "key1")
    assert {:ok, %{data: 2}} = pstate.adapter.get(pstate.adapter_state, "key2")
    assert {:ok, %{data: 3}} = pstate.adapter.get(pstate.adapter_state, "key3")
  end

  # RMX004_1A_T4: Test timer-based flush
  test "RMX004_1A_T4: timer-based flush works" do
    pstate = create_pstate()

    # Stop default writer
    GenServer.stop(MigrationWriter)

    # Start with short flush interval
    {:ok, _pid} = MigrationWriter.start_link(pstate: pstate, flush_interval: 100)

    # Queue a write
    MigrationWriter.queue_write("timer_key", %{data: "timer_test"})

    # Wait for timer to trigger (100ms + buffer)
    Process.sleep(200)

    # Verify data was flushed
    assert {:ok, %{data: "timer_test"}} =
             pstate.adapter.get(pstate.adapter_state, "timer_key")
  end

  # RMX004_1A_T5: Test manual flush/0
  test "RMX004_1A_T5: manual flush works", %{pstate: pstate} do
    # Queue some writes
    MigrationWriter.queue_write("manual1", %{id: "m1"})
    MigrationWriter.queue_write("manual2", %{id: "m2"})

    # Manually flush
    :ok = MigrationWriter.flush()

    # Verify data was written
    assert {:ok, %{id: "m1"}} = pstate.adapter.get(pstate.adapter_state, "manual1")
    assert {:ok, %{id: "m2"}} = pstate.adapter.get(pstate.adapter_state, "manual2")
  end

  # RMX004_1A_T6: Test empty queue flush (noop)
  test "RMX004_1A_T6: flushing empty queue is noop" do
    # Flush empty queue (should not error)
    :ok = MigrationWriter.flush()
    :ok = MigrationWriter.flush()
  end

  # RMX004_1A_T7: Test integration with fetch_and_auto_migrate
  test "RMX004_1A_T7: integration with fetch_and_auto_migrate" do
    # Create pstate with schema
    pstate =
      create_pstate(
        schema: TestSchema,
        data: %{
          "base_card:card1" => %{
            id: "card1",
            front: "Hello",
            back: "Hola",
            # Old format: string instead of map
            metadata: "old_notes"
          }
        }
      )

    # Stop default writer
    GenServer.stop(MigrationWriter)

    # Start writer with pstate
    {:ok, _pid} = MigrationWriter.start_link(pstate: pstate, flush_interval: 100)

    # Fetch entity (should trigger migration and queue write)
    {:ok, migrated} = PState.Internal.fetch_and_auto_migrate(pstate, "base_card:card1")

    # Verify migration occurred
    assert migrated.metadata == %{notes: "old_notes"}

    # Wait for background write (timer-based)
    Process.sleep(200)

    # Fetch again from adapter to verify background write succeeded
    {:ok, raw_data} = pstate.adapter.get(pstate.adapter_state, "base_card:card1")

    # Should now have migrated format in storage
    assert raw_data[:metadata] == %{notes: "old_notes"}
  end
end
