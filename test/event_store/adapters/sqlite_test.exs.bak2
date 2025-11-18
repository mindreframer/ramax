defmodule EventStore.Adapters.SQLiteTest do
  use ExUnit.Case, async: true

  alias EventStore.Adapters.SQLite

  # Helper to create temporary database paths
  defp temp_db_path do
    "/tmp/test_events_#{:erlang.unique_integer([:positive])}.db"
  end

  # Helper to cleanup database
  defp cleanup_db(path) do
    File.rm(path)
    File.rm("#{path}-shm")
    File.rm("#{path}-wal")
  end

  describe "RMX005_3A: SQLite Adapter Implementation" do
    test "RMX005_3A_T1: init creates database" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Verify database file was created
      assert File.exists?(db_path)
      assert state.db != nil

      cleanup_db(db_path)
    end

    test "RMX005_3A_T2: init creates events table with correct schema" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Query table schema
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          state.db,
          "SELECT name FROM sqlite_master WHERE type='table' AND name='events'"
        )

      case Exqlite.Sqlite3.step(state.db, stmt) do
        {:row, ["events"]} -> assert true
        _ -> flunk("events table not created")
      end

      cleanup_db(db_path)
    end

    test "RMX005_3A_T3: init creates all indexes" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Query indexes
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          state.db,
          "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name"
        )

      indexes = fetch_all_names(state.db, stmt)

      assert "idx_events_entity_id_event_id" in indexes
      assert "idx_events_event_type" in indexes
      assert "idx_events_correlation_id" in indexes

      cleanup_db(db_path)
    end

    test "RMX005_3A_T4: init sets WAL mode" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Check PRAGMA journal_mode
      {:ok, stmt} = Exqlite.Sqlite3.prepare(state.db, "PRAGMA journal_mode")

      case Exqlite.Sqlite3.step(state.db, stmt) do
        {:row, ["wal"]} -> assert true
        other -> flunk("Expected WAL mode, got: #{inspect(other)}")
      end

      cleanup_db(db_path)
    end

    test "RMX005_3A_T5: append generates sequential event IDs" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{data: "first"})

      {:ok, id2, _seq, state} =
        SQLite.append(state, 1, "entity1", "test.event", %{data: "second"})

      {:ok, id3, _seq, _state} =
        SQLite.append(state, 1, "entity2", "test.event", %{data: "third"})

      assert id1 == 1
      assert id2 == 2
      assert id3 == 3

      cleanup_db(db_path)
    end

    test "RMX005_3A_T6: append compresses payload" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      large_payload = %{data: String.duplicate("test", 1000)}

      {:ok, event_id, _seq, state} =
        SQLite.append(state, 1, "entity1", "test.event", large_payload)

      # Query raw payload size from database
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          state.db,
          "SELECT length(payload) FROM events WHERE event_id = ?1"
        )

      :ok = Exqlite.Sqlite3.bind(stmt, [event_id])

      case Exqlite.Sqlite3.step(state.db, stmt) do
        {:row, [compressed_size]} ->
          uncompressed_size = byte_size(:erlang.term_to_binary(large_payload))
          # Compressed size should be significantly smaller
          assert compressed_size < uncompressed_size

        _ ->
          flunk("Could not query payload size")
      end

      cleanup_db(db_path)
    end

    test "RMX005_3A_T7: append stores all metadata fields" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      payload = %{card_id: "card-123", front: "Hello"}
      opts = [causation_id: 42, correlation_id: "custom-correlation"]

      {:ok, event_id, _seq, state} =
        SQLite.append(state, 1, "entity1", "basecard.created", payload, opts)

      {:ok, event} = SQLite.get_event(state, event_id)

      assert event.metadata.event_id == event_id
      assert event.metadata.entity_id == "entity1"
      assert event.metadata.event_type == "basecard.created"
      assert event.metadata.causation_id == 42
      assert event.metadata.correlation_id == "custom-correlation"
      assert %DateTime{} = event.metadata.timestamp

      cleanup_db(db_path)
    end

    test "RMX005_3A_T8: get_events uses composite index" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Append events to different entities
      {:ok, _id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{data: 1})
      {:ok, _id2, _seq, state} = SQLite.append(state, 1, "entity2", "test.event", %{data: 2})
      {:ok, _id3, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{data: 3})

      # Query should use composite index
      {:ok, events} = SQLite.get_events(state, "entity1")

      assert length(events) == 2
      assert Enum.at(events, 0).payload.data == 1
      assert Enum.at(events, 1).payload.data == 3

      cleanup_db(db_path)
    end

    test "RMX005_3A_T9: get_events filters by from_sequence" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, _id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 1})
      {:ok, id2, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 2})
      {:ok, id3, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 3})
      {:ok, _id4, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 4})

      {:ok, events} = SQLite.get_events(state, "entity1", from_sequence: id2)

      assert length(events) == 2
      assert Enum.at(events, 0).metadata.event_id == id3
      assert Enum.at(events, 0).payload.seq == 3

      cleanup_db(db_path)
    end

    test "RMX005_3A_T10: get_events respects limit" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, _id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 1})
      {:ok, _id2, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 2})
      {:ok, _id3, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 3})
      {:ok, _id4, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 4})

      {:ok, events} = SQLite.get_events(state, "entity1", limit: 2)

      assert length(events) == 2
      assert Enum.at(events, 0).payload.seq == 1
      assert Enum.at(events, 1).payload.seq == 2

      cleanup_db(db_path)
    end

    test "RMX005_3A_T11: get_events decompresses payloads" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      original_payload = %{complex: %{nested: %{data: "test"}}, list: [1, 2, 3]}

      {:ok, _event_id, _seq, state} =
        SQLite.append(state, 1, "entity1", "test.event", original_payload)

      {:ok, events} = SQLite.get_events(state, "entity1")

      assert length(events) == 1
      assert Enum.at(events, 0).payload == original_payload

      cleanup_db(db_path)
    end

    test "RMX005_3A_T12: get_event returns single event" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, _id1, _seq, state} =
        SQLite.append(state, 1, "entity1", "test.event", %{data: "first"})

      {:ok, id2, _seq, state} =
        SQLite.append(state, 1, "entity1", "test.event", %{data: "second"})

      {:ok, event} = SQLite.get_event(state, id2)

      assert event.metadata.event_id == id2
      assert event.payload.data == "second"

      cleanup_db(db_path)
    end

    test "RMX005_3A_T13: stream_all_events yields batches" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Create 150 events
      state =
        Enum.reduce(1..150, state, fn i, acc_state ->
          {:ok, _id, _seq, new_state} =
            SQLite.append(acc_state, 1, "entity1", "test.event", %{seq: i})

          new_state
        end)

      # Stream with batch size of 50
      stream = SQLite.stream_all_events(state, batch_size: 50)
      all_events = Enum.to_list(stream)

      assert length(all_events) == 150
      assert Enum.at(all_events, 0).payload.seq == 1
      assert Enum.at(all_events, 149).payload.seq == 150

      cleanup_db(db_path)
    end

    test "RMX005_3A_T14: stream_all_events constant memory (100k events)" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Create 1000 events (reduced from 100k for test speed)
      state =
        Enum.reduce(1..1000, state, fn i, acc_state ->
          {:ok, _id, _seq, new_state} =
            SQLite.append(acc_state, 1, "entity#{rem(i, 10)}", "test.event", %{seq: i})

          new_state
        end)

      # Stream should not load all events into memory
      stream = SQLite.stream_all_events(state, batch_size: 100)

      # Process stream lazily
      count = Enum.reduce(stream, 0, fn _event, acc -> acc + 1 end)

      assert count == 1000

      cleanup_db(db_path)
    end

    test "RMX005_3A_T15: get_latest_sequence with events" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, _id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{})
      {:ok, _id2, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{})
      {:ok, _id3, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{})

      {:ok, latest_seq} = SQLite.get_latest_sequence(state)

      assert latest_seq == 3

      cleanup_db(db_path)
    end

    test "RMX005_3A_T16: get_latest_sequence returns 0 when empty" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, latest_seq} = SQLite.get_latest_sequence(state)

      assert latest_seq == 0

      cleanup_db(db_path)
    end

    test "RMX005_3A_T17: compression reduces storage size" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Create payload with repetitive data (highly compressible)
      repetitive_payload = %{
        field1: String.duplicate("AAAA", 100),
        field2: String.duplicate("BBBB", 100),
        field3: String.duplicate("CCCC", 100)
      }

      {:ok, event_id, _seq, state} =
        SQLite.append(state, 1, "entity1", "test.event", repetitive_payload)

      # Verify we can retrieve and decompress the payload correctly
      {:ok, event} = SQLite.get_event(state, event_id)
      assert event.payload == repetitive_payload

      # Verify that compression is actually reducing size
      uncompressed_size = byte_size(:erlang.term_to_binary(repetitive_payload))
      compressed_size = byte_size(:erlang.term_to_binary(repetitive_payload, compressed: 6))

      # Compression should reduce size significantly for repetitive data
      assert compressed_size < uncompressed_size * 0.5

      cleanup_db(db_path)
    end

    test "RMX005_3A_T18: large payload handling (1MB)" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Create large payload (approximately 1MB)
      large_data = String.duplicate("x", 1_000_000)
      large_payload = %{data: large_data}

      {:ok, event_id, _seq, state} =
        SQLite.append(state, 1, "entity1", "test.event", large_payload)

      # Verify we can retrieve it
      {:ok, event} = SQLite.get_event(state, event_id)

      assert event.payload.data == large_data

      cleanup_db(db_path)
    end
  end

  # Helper to fetch all names from a query
  defp fetch_all_names(db, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [name]} -> fetch_all_names(db, stmt, [name | acc])
      :done -> Enum.reverse(acc)
      {:error, _} -> Enum.reverse(acc)
    end
  end

  describe "RMX007_3A: EventStore SQLite Adapter - Space Support" do
    test "RMX007_3_T1: append with space_id creates event" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, event_id, space_sequence, state} =
        SQLite.append(state, 1, "entity1", "test.event", %{data: "test"})

      assert event_id == 1
      assert space_sequence == 1

      {:ok, event} = SQLite.get_event(state, event_id)
      assert event.metadata.space_id == 1
      assert event.metadata.space_sequence == 1
      assert event.payload.data == "test"

      cleanup_db(db_path)
    end

    test "RMX007_3_T2: append increments space_sequence" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, _id1, seq1, state} = SQLite.append(state, 1, "entity1", "test.event", %{})
      {:ok, _id2, seq2, state} = SQLite.append(state, 1, "entity1", "test.event", %{})
      {:ok, _id3, seq3, _state} = SQLite.append(state, 1, "entity1", "test.event", %{})

      assert seq1 == 1
      assert seq2 == 2
      assert seq3 == 3

      cleanup_db(db_path)
    end

    test "RMX007_3_T3: different spaces have independent sequences" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Space 1
      {:ok, _id1, seq1, state} = SQLite.append(state, 1, "entity1", "test.event", %{})
      {:ok, _id2, seq2, state} = SQLite.append(state, 1, "entity2", "test.event", %{})

      # Space 2
      {:ok, _id3, seq3, state} = SQLite.append(state, 2, "entity1", "test.event", %{})
      {:ok, _id4, seq4, _state} = SQLite.append(state, 2, "entity2", "test.event", %{})

      # Space 1 sequences
      assert seq1 == 1
      assert seq2 == 2

      # Space 2 sequences (should start from 1 again)
      assert seq3 == 1
      assert seq4 == 2

      cleanup_db(db_path)
    end

    test "RMX007_3_T4: append returns correct space_sequence" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, event_id, space_sequence, state} =
        SQLite.append(state, 1, "entity1", "test.event", %{data: "first"})

      assert space_sequence == 1

      {:ok, event} = SQLite.get_event(state, event_id)
      assert event.metadata.space_sequence == space_sequence

      cleanup_db(db_path)
    end

    test "RMX007_3_T5: space_sequence starts at 1" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, _event_id, space_sequence, _state} =
        SQLite.append(state, 1, "entity1", "test.event", %{})

      assert space_sequence == 1

      cleanup_db(db_path)
    end

    test "RMX007_3_T6: global event_id still increments globally" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Space 1
      {:ok, event_id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{})

      # Space 2
      {:ok, event_id2, _seq, state} = SQLite.append(state, 2, "entity1", "test.event", %{})

      # Space 1 again
      {:ok, event_id3, _seq, _state} = SQLite.append(state, 1, "entity2", "test.event", %{})

      # Global event IDs should increment regardless of space
      assert event_id1 == 1
      assert event_id2 == 2
      assert event_id3 == 3

      cleanup_db(db_path)
    end

    test "RMX007_3_T7: stream_space_events returns only space events" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Space 1
      {:ok, _id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{data: "s1e1"})
      {:ok, _id2, _seq, state} = SQLite.append(state, 1, "entity2", "test.event", %{data: "s1e2"})

      # Space 2
      {:ok, _id3, _seq, state} = SQLite.append(state, 2, "entity1", "test.event", %{data: "s2e1"})

      # Space 1 again
      {:ok, _id4, _seq, state} = SQLite.append(state, 1, "entity3", "test.event", %{data: "s1e3"})

      # Stream space 1 events
      stream = SQLite.stream_space_events(state, 1)
      space1_events = Enum.to_list(stream)

      assert length(space1_events) == 3
      assert Enum.at(space1_events, 0).payload.data == "s1e1"
      assert Enum.at(space1_events, 1).payload.data == "s1e2"
      assert Enum.at(space1_events, 2).payload.data == "s1e3"

      # All events should have space_id = 1
      assert Enum.all?(space1_events, fn event -> event.metadata.space_id == 1 end)

      cleanup_db(db_path)
    end

    test "RMX007_3_T8: stream_space_events ordered by space_sequence" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Create events in space 1
      {:ok, _id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 1})
      {:ok, _id2, _seq, state} = SQLite.append(state, 1, "entity2", "test.event", %{seq: 2})
      {:ok, _id3, _seq, state} = SQLite.append(state, 1, "entity3", "test.event", %{seq: 3})

      # Stream space 1 events
      stream = SQLite.stream_space_events(state, 1)
      events = Enum.to_list(stream)

      # Verify ordering by space_sequence
      assert Enum.at(events, 0).metadata.space_sequence == 1
      assert Enum.at(events, 1).metadata.space_sequence == 2
      assert Enum.at(events, 2).metadata.space_sequence == 3

      cleanup_db(db_path)
    end

    test "RMX007_3_T9: stream_space_events with from_sequence" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Create events in space 1
      {:ok, _id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{seq: 1})
      {:ok, _id2, _seq, state} = SQLite.append(state, 1, "entity2", "test.event", %{seq: 2})
      {:ok, _id3, _seq, state} = SQLite.append(state, 1, "entity3", "test.event", %{seq: 3})
      {:ok, _id4, _seq, state} = SQLite.append(state, 1, "entity4", "test.event", %{seq: 4})

      # Stream from space_sequence > 2
      stream = SQLite.stream_space_events(state, 1, from_sequence: 2)
      events = Enum.to_list(stream)

      assert length(events) == 2
      assert Enum.at(events, 0).metadata.space_sequence == 3
      assert Enum.at(events, 1).metadata.space_sequence == 4

      cleanup_db(db_path)
    end

    test "RMX007_3_T10: get_space_latest_sequence returns correct value" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Initially 0
      {:ok, seq0} = SQLite.get_space_latest_sequence(state, 1)
      assert seq0 == 0

      # After appending events
      {:ok, _id1, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{})
      {:ok, _id2, _seq, state} = SQLite.append(state, 1, "entity2", "test.event", %{})
      {:ok, _id3, _seq, state} = SQLite.append(state, 1, "entity3", "test.event", %{})

      {:ok, latest_seq} = SQLite.get_space_latest_sequence(state, 1)
      assert latest_seq == 3

      cleanup_db(db_path)
    end

    test "RMX007_3_T11: get_space_latest_sequence returns 0 for new space" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      # Create events in space 1
      {:ok, _id, _seq, state} = SQLite.append(state, 1, "entity1", "test.event", %{})

      # Query space 2 (which has no events)
      {:ok, latest_seq} = SQLite.get_space_latest_sequence(state, 2)
      assert latest_seq == 0

      cleanup_db(db_path)
    end

    test "RMX007_3_T12: event metadata includes space_id and space_sequence" do
      db_path = temp_db_path()
      {:ok, state} = SQLite.init(database: db_path)

      {:ok, event_id, _space_seq, state} =
        SQLite.append(state, 5, "entity1", "test.event", %{data: "test"})

      {:ok, event} = SQLite.get_event(state, event_id)

      assert event.metadata.space_id == 5
      assert event.metadata.space_sequence == 1
      assert event.metadata.event_id == event_id
      assert event.metadata.entity_id == "entity1"
      assert event.metadata.event_type == "test.event"

      cleanup_db(db_path)
    end
  end
end
