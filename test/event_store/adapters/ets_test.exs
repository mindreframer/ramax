defmodule EventStore.Adapters.ETSTest do
  use ExUnit.Case, async: true

  alias EventStore.Adapters.ETS

  describe "RMX005_2A: ETS Adapter Implementation" do
    test "RMX005_2A_T1: init creates tables and atomic counter" do
      table_name = :"test_events_#{:erlang.unique_integer([:positive])}"
      {:ok, state} = ETS.init(table_name: table_name)

      # Verify main events table exists
      assert :ets.info(state.events) != :undefined
      assert :ets.info(state.events)[:type] == :ordered_set

      # Verify entity index table exists
      assert :ets.info(state.entity_index) != :undefined
      assert :ets.info(state.entity_index)[:type] == :ordered_set

      # Verify sequence counter exists
      assert is_reference(state.sequence)
      assert :atomics.get(state.sequence, 1) == 0

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T2: append generates sequential event IDs" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      {:ok, id1, state} = ETS.append(state, "entity1", "test.event", %{data: "first"})
      {:ok, id2, state} = ETS.append(state, "entity1", "test.event", %{data: "second"})
      {:ok, id3, _state} = ETS.append(state, "entity2", "test.event", %{data: "third"})

      assert id1 == 1
      assert id2 == 2
      assert id3 == 3

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T3: append stores event in events table" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      payload = %{card_id: "card-123", front: "Hello", back: "Hola"}
      {:ok, event_id, state} = ETS.append(state, "entity1", "basecard.created", payload)

      # Lookup event from events table
      [{^event_id, event}] = :ets.lookup(state.events, event_id)

      assert event.metadata.event_id == event_id
      assert event.metadata.entity_id == "entity1"
      assert event.metadata.event_type == "basecard.created"
      assert event.payload == payload

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T4: append stores entity index entry" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      {:ok, event_id, state} = ETS.append(state, "entity1", "test.event", %{data: "test"})

      # Check entity index entry exists
      assert :ets.lookup(state.entity_index, {"entity1", event_id}) == [
               {{"entity1", event_id}, nil}
             ]

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T5: append creates metadata with timestamp" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      before = DateTime.utc_now()
      {:ok, event_id, state} = ETS.append(state, "entity1", "test.event", %{})
      after_time = DateTime.utc_now()

      [{^event_id, event}] = :ets.lookup(state.events, event_id)

      # Verify timestamp is a DateTime
      assert %DateTime{} = event.metadata.timestamp

      # Verify timestamp is between before and after
      assert DateTime.compare(event.metadata.timestamp, before) in [:gt, :eq]
      assert DateTime.compare(event.metadata.timestamp, after_time) in [:lt, :eq]

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T6: append accepts causation_id and correlation_id" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      opts = [causation_id: 42, correlation_id: "custom-correlation-id"]
      {:ok, event_id, state} = ETS.append(state, "entity1", "test.event", %{}, opts)

      [{^event_id, event}] = :ets.lookup(state.events, event_id)

      assert event.metadata.causation_id == 42
      assert event.metadata.correlation_id == "custom-correlation-id"

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T7: get_events returns events for entity" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      {:ok, _id1, state} = ETS.append(state, "entity1", "test.created", %{name: "first"})
      {:ok, _id2, state} = ETS.append(state, "entity1", "test.updated", %{name: "second"})
      {:ok, _id3, state} = ETS.append(state, "entity2", "test.created", %{name: "other"})
      {:ok, _id4, state} = ETS.append(state, "entity1", "test.deleted", %{name: "third"})

      {:ok, events} = ETS.get_events(state, "entity1")

      assert length(events) == 3
      assert Enum.at(events, 0).metadata.event_type == "test.created"
      assert Enum.at(events, 1).metadata.event_type == "test.updated"
      assert Enum.at(events, 2).metadata.event_type == "test.deleted"

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T8: get_events filters by from_sequence" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      {:ok, _id1, state} = ETS.append(state, "entity1", "test.event", %{seq: 1})
      {:ok, id2, state} = ETS.append(state, "entity1", "test.event", %{seq: 2})
      {:ok, id3, state} = ETS.append(state, "entity1", "test.event", %{seq: 3})
      {:ok, _id4, state} = ETS.append(state, "entity1", "test.event", %{seq: 4})

      {:ok, events} = ETS.get_events(state, "entity1", from_sequence: id2)

      assert length(events) == 2
      assert Enum.at(events, 0).metadata.event_id == id3
      assert Enum.at(events, 0).payload.seq == 3

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T9: get_events respects limit" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      {:ok, _id1, state} = ETS.append(state, "entity1", "test.event", %{seq: 1})
      {:ok, _id2, state} = ETS.append(state, "entity1", "test.event", %{seq: 2})
      {:ok, _id3, state} = ETS.append(state, "entity1", "test.event", %{seq: 3})
      {:ok, _id4, state} = ETS.append(state, "entity1", "test.event", %{seq: 4})

      {:ok, events} = ETS.get_events(state, "entity1", limit: 2)

      assert length(events) == 2
      assert Enum.at(events, 0).payload.seq == 1
      assert Enum.at(events, 1).payload.seq == 2

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T10: get_events returns empty for unknown entity" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      {:ok, _id1, state} = ETS.append(state, "entity1", "test.event", %{})

      {:ok, events} = ETS.get_events(state, "unknown_entity")

      assert events == []

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T11: get_event returns single event by ID" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      {:ok, _id1, state} = ETS.append(state, "entity1", "test.event", %{data: "first"})
      {:ok, id2, state} = ETS.append(state, "entity1", "test.event", %{data: "second"})

      {:ok, event} = ETS.get_event(state, id2)

      assert event.metadata.event_id == id2
      assert event.payload.data == "second"

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T12: get_event returns error for missing event" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      assert {:error, :not_found} = ETS.get_event(state, 999)

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T13: stream_all_events yields batches" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      # Create 150 events
      state =
        Enum.reduce(1..150, state, fn i, acc_state ->
          {:ok, _id, new_state} = ETS.append(acc_state, "entity1", "test.event", %{seq: i})
          new_state
        end)

      # Stream with batch size of 50
      stream = ETS.stream_all_events(state, batch_size: 50)
      all_events = Enum.to_list(stream)

      assert length(all_events) == 150
      assert Enum.at(all_events, 0).payload.seq == 1
      assert Enum.at(all_events, 149).payload.seq == 150

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T14: stream_all_events filters by from_sequence" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      {:ok, _id1, state} = ETS.append(state, "entity1", "test.event", %{seq: 1})
      {:ok, _id2, state} = ETS.append(state, "entity1", "test.event", %{seq: 2})
      {:ok, id3, state} = ETS.append(state, "entity1", "test.event", %{seq: 3})
      {:ok, _id4, state} = ETS.append(state, "entity1", "test.event", %{seq: 4})
      {:ok, _id5, state} = ETS.append(state, "entity1", "test.event", %{seq: 5})

      stream = ETS.stream_all_events(state, from_sequence: id3)
      events = Enum.to_list(stream)

      assert length(events) == 2
      assert Enum.at(events, 0).payload.seq == 4
      assert Enum.at(events, 1).payload.seq == 5

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T15: get_latest_sequence returns current sequence" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      # Initial sequence should be 0
      {:ok, seq0} = ETS.get_latest_sequence(state)
      assert seq0 == 0

      # After appending 3 events
      {:ok, _id1, state} = ETS.append(state, "entity1", "test.event", %{})
      {:ok, _id2, state} = ETS.append(state, "entity1", "test.event", %{})
      {:ok, _id3, state} = ETS.append(state, "entity1", "test.event", %{})

      {:ok, seq3} = ETS.get_latest_sequence(state)
      assert seq3 == 3

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T16: concurrent appends produce unique IDs" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      # Spawn multiple processes to append concurrently
      tasks =
        1..100
        |> Enum.map(fn i ->
          Task.async(fn ->
            {:ok, id, _state} = ETS.append(state, "entity#{i}", "test.event", %{seq: i})
            id
          end)
        end)

      # Collect all event IDs
      event_ids = Enum.map(tasks, &Task.await/1)

      # All IDs should be unique
      assert length(Enum.uniq(event_ids)) == 100

      # IDs should be sequential (1 to 100)
      assert Enum.sort(event_ids) == Enum.to_list(1..100)

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end

    test "RMX005_2A_T17: large dataset (10k events) performance" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      # Append 10k events and measure time
      {time_us, final_state} =
        :timer.tc(fn ->
          Enum.reduce(1..10_000, state, fn i, acc_state ->
            {:ok, _id, new_state} =
              ETS.append(acc_state, "entity#{rem(i, 100)}", "test.event", %{seq: i})

            new_state
          end)
        end)

      # Should complete in reasonable time (< 1 second)
      assert time_us < 1_000_000

      # Verify all events stored
      {:ok, latest_seq} = ETS.get_latest_sequence(final_state)
      assert latest_seq == 10_000

      # Cleanup
      :ets.delete(final_state.events)
      :ets.delete(final_state.entity_index)
    end

    test "RMX005_2A_T18: entity query efficiency (no list accumulation)" do
      {:ok, state} = ETS.init(table_name: :"test_events_#{:erlang.unique_integer([:positive])}")

      # Create 10k events for different entities
      state =
        Enum.reduce(1..10_000, state, fn i, acc_state ->
          entity_id = "entity#{rem(i, 100)}"
          {:ok, _id, new_state} = ETS.append(acc_state, entity_id, "test.event", %{seq: i})
          new_state
        end)

      # Query single entity (should be fast due to composite index)
      {time_us, {:ok, events}} =
        :timer.tc(fn ->
          ETS.get_events(state, "entity50")
        end)

      # Should return correct number of events (100 events for entity50)
      assert length(events) == 100

      # Should complete quickly (< 10ms = 10,000 microseconds)
      assert time_us < 10_000

      # Cleanup
      :ets.delete(state.events)
      :ets.delete(state.entity_index)
    end
  end
end
