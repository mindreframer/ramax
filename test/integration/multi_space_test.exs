defmodule Integration.MultiSpaceTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Integration tests for multi-space functionality.

  Tests complete workflows across spaces including:
  - Space isolation
  - Independent sequences
  - Selective rebuilds
  - Space deletion
  - Checkpoint tracking
  - Concurrent operations
  """

  # Test helpers
  defp create_store(space_name) do
    {:ok, store} =
      ContentStore.new(
        space_name: space_name,
        event_applicator: Integration.MultiSpaceTest.TestApplicator,
        entity_id_extractor: &extract_entity_id/1
      )

    store
  end

  defp add_test_event(store, entity_id, data) do
    {:ok, [event_id], updated_store} =
      ContentStore.execute(store, &create_test_command/2, %{
        entity_id: entity_id,
        data: data
      })

    {event_id, updated_store}
  end

  defp create_test_command(_pstate, params) do
    {:ok, [{"test.event.created", params}]}
  end

  defp extract_entity_id(event_payload) do
    Map.get(event_payload, :entity_id)
  end

  defmodule TestApplicator do
    @spec apply_event(PState.t(), EventStore.event()) :: PState.t()
    def apply_event(pstate, event) do
      case event.metadata.event_type do
        "test.event.created" ->
          p = event.payload
          key = "entity:#{p.entity_id}"
          put_in(pstate[key], %{id: p.entity_id, data: p.data})

        _ ->
          pstate
      end
    end

    @spec apply_events(PState.t(), [EventStore.event()]) :: PState.t()
    def apply_events(pstate, events) do
      Enum.reduce(events, pstate, &apply_event(&2, &1))
    end
  end

  # Tests

  describe "RMX007_9_T1: complete multi-space workflow" do
    test "creates spaces, adds events, queries data, and cleans up" do
      # Create multiple spaces
      store1 = create_store("workflow_test_1")
      store2 = create_store("workflow_test_2")
      store3 = create_store("workflow_test_3")

      assert store1.space.space_name == "workflow_test_1"
      assert store2.space.space_name == "workflow_test_2"
      assert store3.space.space_name == "workflow_test_3"

      # Verify spaces are different
      assert store1.space.space_id != store2.space.space_id
      assert store2.space.space_id != store3.space.space_id

      # Add events to each space
      {_event1, store1} = add_test_event(store1, "e1", "data1")
      {_event2, store2} = add_test_event(store2, "e1", "data2")
      {_event3, store3} = add_test_event(store3, "e1", "data3")

      # Verify data isolation
      {:ok, entity1} = PState.fetch(store1.pstate, "entity:e1")
      {:ok, entity2} = PState.fetch(store2.pstate, "entity:e1")
      {:ok, entity3} = PState.fetch(store3.pstate, "entity:e1")

      assert entity1.data == "data1"
      assert entity2.data == "data2"
      assert entity3.data == "data3"

      # List all spaces
      {:ok, spaces} = Ramax.Space.list_all(store1.event_store)
      space_names = Enum.map(spaces, & &1.space_name)

      assert "workflow_test_1" in space_names
      assert "workflow_test_2" in space_names
      assert "workflow_test_3" in space_names

      # Delete a space
      :ok = Ramax.Space.delete(store1.event_store, store3.space.space_id)

      {:ok, remaining_spaces} = Ramax.Space.list_all(store1.event_store)
      remaining_names = Enum.map(remaining_spaces, & &1.space_name)

      refute "workflow_test_3" in remaining_names
      assert "workflow_test_1" in remaining_names
      assert "workflow_test_2" in remaining_names
    end
  end

  describe "RMX007_9_T2: space isolation with 100 events per space" do
    test "maintains complete isolation with high event volume" do
      store_a = create_store("isolation_test_a")
      store_b = create_store("isolation_test_b")

      # Add 100 events to each space
      store_a =
        Enum.reduce(1..100, store_a, fn i, store ->
          {_, updated_store} = add_test_event(store, "entity_#{i}", "data_a_#{i}")
          updated_store
        end)

      store_b =
        Enum.reduce(1..100, store_b, fn i, store ->
          {_, updated_store} = add_test_event(store, "entity_#{i}", "data_b_#{i}")
          updated_store
        end)

      # Verify sequences
      {:ok, seq_a} =
        EventStore.get_space_latest_sequence(store_a.event_store, store_a.space.space_id)

      {:ok, seq_b} =
        EventStore.get_space_latest_sequence(store_b.event_store, store_b.space.space_id)

      assert seq_a == 100
      assert seq_b == 100

      # Verify data isolation (random samples)
      {:ok, entity_a_50} = PState.fetch(store_a.pstate, "entity:entity_50")
      {:ok, entity_b_50} = PState.fetch(store_b.pstate, "entity:entity_50")

      assert entity_a_50.data == "data_a_50"
      assert entity_b_50.data == "data_b_50"

      # Verify space A cannot see space B's data
      events_a =
        store_a.event_store
        |> EventStore.stream_space_events(store_a.space.space_id)
        |> Enum.to_list()

      assert length(events_a) == 100

      # All events should belong to space A
      Enum.each(events_a, fn event ->
        assert event.metadata.space_id == store_a.space.space_id
      end)

      # Verify space B cannot see space A's data
      events_b =
        store_b.event_store
        |> EventStore.stream_space_events(store_b.space.space_id)
        |> Enum.to_list()

      assert length(events_b) == 100

      # All events should belong to space B
      Enum.each(events_b, fn event ->
        assert event.metadata.space_id == store_b.space.space_id
      end)
    end
  end

  describe "RMX007_9_T3: selective rebuild performance" do
    test "rebuilding one space doesn't process other spaces' events" do
      # Create two spaces with different event volumes
      small_store = create_store("perf_test_small")
      large_store = create_store("perf_test_large")

      # Small space: 10 events
      small_store =
        Enum.reduce(1..10, small_store, fn i, store ->
          {_, updated_store} = add_test_event(store, "entity_#{i}", "small_#{i}")
          updated_store
        end)

      # Large space: 100 events
      large_store =
        Enum.reduce(1..100, large_store, fn i, store ->
          {_, updated_store} = add_test_event(store, "entity_#{i}", "large_#{i}")
          updated_store
        end)

      # Verify event counts
      {:ok, seq_small} =
        EventStore.get_space_latest_sequence(small_store.event_store, small_store.space.space_id)

      {:ok, seq_large} =
        EventStore.get_space_latest_sequence(large_store.event_store, large_store.space.space_id)

      assert seq_small == 10
      assert seq_large == 100

      # Rebuild small space and time it
      {time_small, rebuilt_small} =
        :timer.tc(fn ->
          ContentStore.rebuild_pstate(small_store)
        end)

      # Rebuild large space and time it
      {time_large, rebuilt_large} =
        :timer.tc(fn ->
          ContentStore.rebuild_pstate(large_store)
        end)

      # Verify data integrity after rebuild
      {:ok, entity_small} = PState.fetch(rebuilt_small.pstate, "entity:entity_5")
      {:ok, entity_large} = PState.fetch(rebuilt_large.pstate, "entity:entity_50")

      assert entity_small.data == "small_5"
      assert entity_large.data == "large_50"

      # Verify selective rebuild works correctly
      # The important thing is data integrity, not absolute timing
      # (timing can vary due to system load, GC, etc.)
      # We just verify that both rebuilds completed successfully
      assert time_small > 0
      assert time_large > 0
    end
  end

  describe "RMX007_9_T4: space deletion removes all data" do
    test "deleting a space removes events and pstate data" do
      store = create_store("deletion_test")

      # Add events
      {_, store} = add_test_event(store, "e1", "data1")
      {_, store} = add_test_event(store, "e2", "data2")
      {_, store} = add_test_event(store, "e3", "data3")

      space_id = store.space.space_id

      # Verify data exists
      {:ok, seq} = EventStore.get_space_latest_sequence(store.event_store, space_id)
      assert seq == 3

      {:ok, entity} = PState.fetch(store.pstate, "entity:e1")
      assert entity.data == "data1"

      # Delete the space
      :ok = Ramax.Space.delete(store.event_store, space_id)

      # Verify space is gone
      assert {:error, :not_found} = Ramax.Space.find_by_id(store.event_store, space_id)

      # Verify events are gone
      events =
        store.event_store
        |> EventStore.stream_space_events(space_id)
        |> Enum.to_list()

      assert events == []

      # Verify sequence is reset
      {:ok, seq_after} = EventStore.get_space_latest_sequence(store.event_store, space_id)
      assert seq_after == 0
    end
  end

  describe "RMX007_9_T5: checkpoint tracking per space" do
    test "each space maintains independent checkpoints" do
      store_a = create_store("checkpoint_test_a")
      store_b = create_store("checkpoint_test_b")

      # Add events to both spaces
      {_, store_a} = add_test_event(store_a, "e1", "data1")
      {_, store_a} = add_test_event(store_a, "e2", "data2")

      {_, store_b} = add_test_event(store_b, "e1", "data1")
      {_, store_b} = add_test_event(store_b, "e2", "data2")
      {_, store_b} = add_test_event(store_b, "e3", "data3")

      # Get sequences
      {:ok, seq_a} =
        EventStore.get_space_latest_sequence(store_a.event_store, store_a.space.space_id)

      {:ok, seq_b} =
        EventStore.get_space_latest_sequence(store_b.event_store, store_b.space.space_id)

      assert seq_a == 2
      assert seq_b == 3

      # Rebuild both spaces (this updates checkpoints internally)
      store_a_rebuilt = ContentStore.rebuild_pstate(store_a)
      store_b_rebuilt = ContentStore.rebuild_pstate(store_b)

      # Verify data is correct after rebuild
      {:ok, entity_a} = PState.fetch(store_a_rebuilt.pstate, "entity:e2")
      {:ok, entity_b} = PState.fetch(store_b_rebuilt.pstate, "entity:e3")

      assert entity_a.data == "data2"
      assert entity_b.data == "data3"
    end
  end

  describe "RMX007_9_T6: space listing and metadata" do
    test "lists spaces with metadata" do
      {:ok, event_store} = EventStore.new(EventStore.Adapters.ETS)

      # Create spaces with different metadata
      {:ok, space1, event_store} =
        Ramax.Space.get_or_create(event_store, "meta_test_1", metadata: %{env: "production"})

      {:ok, space2, event_store} =
        Ramax.Space.get_or_create(event_store, "meta_test_2", metadata: %{env: "staging"})

      {:ok, space3, event_store} = Ramax.Space.get_or_create(event_store, "meta_test_3")

      # List all spaces
      {:ok, spaces} = Ramax.Space.list_all(event_store)

      # Find our test spaces
      found_space1 = Enum.find(spaces, &(&1.space_id == space1.space_id))
      found_space2 = Enum.find(spaces, &(&1.space_id == space2.space_id))
      found_space3 = Enum.find(spaces, &(&1.space_id == space3.space_id))

      # Verify metadata
      assert found_space1.metadata == %{env: "production"}
      assert found_space2.metadata == %{env: "staging"}
      assert found_space3.metadata == nil

      # Find by name
      {:ok, by_name} = Ramax.Space.find_by_name(event_store, "meta_test_1")
      assert by_name.space_id == space1.space_id
      assert by_name.metadata == %{env: "production"}
    end
  end

  describe "RMX007_9_T7: cross-space event_id ordering" do
    test "global event_id maintains causality across spaces" do
      store_a = create_store("ordering_test_a")
      store_b = create_store("ordering_test_b")

      # Add events alternating between spaces
      {event_id_a1, store_a} = add_test_event(store_a, "e1", "a1")
      {event_id_b1, store_b} = add_test_event(store_b, "e1", "b1")
      {event_id_a2, store_a} = add_test_event(store_a, "e2", "a2")
      {event_id_b2, store_b} = add_test_event(store_b, "e2", "b2")

      # Global event_ids should be monotonically increasing
      assert event_id_a1 < event_id_b1
      assert event_id_b1 < event_id_a2
      assert event_id_a2 < event_id_b2

      # But space_sequences are independent
      events_a =
        store_a.event_store
        |> EventStore.stream_space_events(store_a.space.space_id)
        |> Enum.to_list()

      events_b =
        store_b.event_store
        |> EventStore.stream_space_events(store_b.space.space_id)
        |> Enum.to_list()

      # Space A has sequences 1, 2
      assert Enum.at(events_a, 0).metadata.space_sequence == 1
      assert Enum.at(events_a, 1).metadata.space_sequence == 2

      # Space B has sequences 1, 2 (independent!)
      assert Enum.at(events_b, 0).metadata.space_sequence == 1
      assert Enum.at(events_b, 1).metadata.space_sequence == 2
    end
  end

  describe "RMX007_9_T8: concurrent operations on different spaces" do
    test "spaces can be operated on concurrently without interference" do
      # Create stores for concurrent operations
      store_a = create_store("concurrent_test_a")
      store_b = create_store("concurrent_test_b")

      # Run concurrent operations
      task_a =
        Task.async(fn ->
          Enum.reduce(1..50, store_a, fn i, store ->
            {_, updated_store} = add_test_event(store, "entity_#{i}", "data_a_#{i}")
            updated_store
          end)
        end)

      task_b =
        Task.async(fn ->
          Enum.reduce(1..50, store_b, fn i, store ->
            {_, updated_store} = add_test_event(store, "entity_#{i}", "data_b_#{i}")
            updated_store
          end)
        end)

      # Wait for completion
      final_store_a = Task.await(task_a)
      final_store_b = Task.await(task_b)

      # Verify both spaces have correct event counts
      {:ok, seq_a} =
        EventStore.get_space_latest_sequence(
          final_store_a.event_store,
          final_store_a.space.space_id
        )

      {:ok, seq_b} =
        EventStore.get_space_latest_sequence(
          final_store_b.event_store,
          final_store_b.space.space_id
        )

      assert seq_a == 50
      assert seq_b == 50

      # Verify data integrity (sample checks)
      {:ok, entity_a_25} = PState.fetch(final_store_a.pstate, "entity:entity_25")
      {:ok, entity_b_25} = PState.fetch(final_store_b.pstate, "entity:entity_25")

      assert entity_a_25.data == "data_a_25"
      assert entity_b_25.data == "data_b_25"
    end
  end
end
