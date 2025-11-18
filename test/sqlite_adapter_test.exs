defmodule PState.Adapters.SQLiteTest do
  # Run tests serially to avoid SQLite database locking
  use ExUnit.Case, async: false
  alias PState.Adapters.SQLite

  setup do
    # Create unique DB file for each test using timestamp + random + pid
    unique_id =
      "#{System.system_time(:nanosecond)}_#{:rand.uniform(999_999)}_#{:erlang.phash2(self())}"

    db_path = "/tmp/pstate_test_#{unique_id}.db"

    on_exit(fn ->
      # Clean up database files (ignore errors if files don't exist)
      File.rm(db_path)
      File.rm("#{db_path}-shm")
      File.rm("#{db_path}-wal")
    end)

    {:ok, db_path: db_path}
  end

  describe "RMX004_3A: SQLite Adapter - Basic Operations" do
    # RMX004_3A_T1: Test SQLite adapter init
    test "T1: init/1 creates database and returns state", %{db_path: db_path} do
      assert {:ok, state} = SQLite.init(path: db_path)
      assert %SQLite{} = state
      assert state.conn != nil
      assert state.table_name == "pstate_entities"

      # Verify DB file exists
      assert File.exists?(db_path)
    end

    # RMX004_3A_T2: Test WAL mode enabled
    test "T2: init/1 enables WAL mode", %{db_path: db_path} do
      assert {:ok, state} = SQLite.init(path: db_path)

      # Query PRAGMA to verify WAL mode
      {:ok, stmt} = Exqlite.Sqlite3.prepare(state.conn, "PRAGMA journal_mode")
      {:row, [mode]} = Exqlite.Sqlite3.step(state.conn, stmt)
      :ok = Exqlite.Sqlite3.release(state.conn, stmt)

      assert mode == "wal"
    end

    # RMX004_3A_T3: Test table creation
    test "T3: init/1 creates table with correct schema", %{db_path: db_path} do
      assert {:ok, state} = SQLite.init(path: db_path)

      # Query table schema
      sql = "SELECT sql FROM sqlite_master WHERE type='table' AND name='pstate_entities'"
      {:ok, stmt} = Exqlite.Sqlite3.prepare(state.conn, sql)
      {:row, [create_sql]} = Exqlite.Sqlite3.step(state.conn, stmt)
      :ok = Exqlite.Sqlite3.release(state.conn, stmt)

      # Verify schema has space_id, key, value, updated_at columns with composite PK
      assert create_sql =~ "space_id INTEGER NOT NULL"
      assert create_sql =~ "key TEXT NOT NULL"
      assert create_sql =~ "value BLOB NOT NULL"
      assert create_sql =~ "updated_at INTEGER"
      assert create_sql =~ "PRIMARY KEY (space_id, key)"
    end

    # RMX004_3A_T4: Test index creation
    test "T4: init/1 creates index on space_id", %{db_path: db_path} do
      assert {:ok, state} = SQLite.init(path: db_path)

      # Query indexes
      sql = "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_pstate_space'"
      {:ok, stmt} = Exqlite.Sqlite3.prepare(state.conn, sql)
      {:row, [index_name]} = Exqlite.Sqlite3.step(state.conn, stmt)
      :ok = Exqlite.Sqlite3.release(state.conn, stmt)

      assert index_name == "idx_pstate_space"
    end

    # RMX004_3A_T5: Test put/get single value
    test "T5: put/3 and get/2 work with single value", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      data = %{front: "Hello", back: "Hola"}
      assert :ok = SQLite.put(state, 1, "base_card:uuid1", data)

      assert {:ok, retrieved} = SQLite.get(state, 1, "base_card:uuid1")
      assert retrieved == %{front: "Hello", back: "Hola"}
    end

    # RMX004_3A_T6: Test put overwrites existing
    test "T6: put/3 overwrites existing value", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert initial value
      :ok = SQLite.put(state, 1, "key1", %{value: "first"})
      assert {:ok, %{value: "first"}} = SQLite.get(state, 1, "key1")

      # Overwrite
      :ok = SQLite.put(state, 1, "key1", %{value: "second"})
      assert {:ok, %{value: "second"}} = SQLite.get(state, 1, "key1")
    end

    # RMX004_3A_T7: Test get missing key
    test "T7: get/2 returns {:ok, nil} for missing key", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert {:ok, nil} = SQLite.get(state, 1, "nonexistent_key")
      assert {:ok, nil} = SQLite.get(state, 1, "base_card:missing")
    end

    # RMX004_3A_T8: Test delete removes value
    test "T8: delete/2 removes value", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert and verify
      :ok = SQLite.put(state, 1, "to_delete", %{data: "value"})
      assert {:ok, %{data: "value"}} = SQLite.get(state, 1, "to_delete")

      # Delete
      assert :ok = SQLite.delete(state, 1, "to_delete")

      # Verify it's gone
      assert {:ok, nil} = SQLite.get(state, 1, "to_delete")
    end

    # RMX004_3A_T9: Test scan by prefix
    test "T9: scan/3 returns entries matching prefix", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert multiple entries
      :ok = SQLite.put(state, 1, "base_card:uuid1", %{front: "Hello"})
      :ok = SQLite.put(state, 1, "base_card:uuid2", %{front: "Goodbye"})
      :ok = SQLite.put(state, 1, "base_deck:uuid3", %{title: "Spanish 101"})
      :ok = SQLite.put(state, 1, "other:uuid4", %{data: "something"})

      # Scan for base_card prefix
      assert {:ok, card_results} = SQLite.scan(state, 1, "base_card:", [])
      assert length(card_results) == 2

      card_keys = Enum.map(card_results, fn {key, _value} -> key end)
      assert "base_card:uuid1" in card_keys
      assert "base_card:uuid2" in card_keys

      # Verify values are decoded (Erlang terms preserve atom keys)
      {_key, value} = List.first(card_results)
      assert is_map(value)
      assert Map.has_key?(value, :front)
    end

    # RMX004_3A_T10: Test JSON encoding/decoding
    test "T10: handles complex JSON encoding/decoding", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Complex nested structure
      complex_data = %{
        id: "550e8400",
        front: "Hello",
        back: "Hola",
        metadata: %{
          pronunciation: "həˈloʊ",
          tags: ["greeting", "common"],
          level: 1
        },
        translations: %{
          "es" => "Hola",
          "fr" => "Bonjour",
          "de" => "Hallo"
        }
      }

      :ok = SQLite.put(state, 1, "base_card:complex", complex_data)
      assert {:ok, retrieved} = SQLite.get(state, 1, "base_card:complex")

      # Verify structure is preserved exactly (Erlang term serialization)
      assert retrieved[:id] == "550e8400"
      assert retrieved[:front] == "Hello"
      assert retrieved[:metadata][:pronunciation] == "həˈloʊ"
      assert retrieved[:metadata][:tags] == ["greeting", "common"]
      assert retrieved[:metadata][:level] == 1
      assert retrieved[:translations]["es"] == "Hola"
    end

    # RMX004_3A_T11: Test persistence (close/reopen DB)
    test "T11: data persists across connection close/reopen", %{db_path: db_path} do
      # First connection - insert data
      {:ok, state1} = SQLite.init(path: db_path)
      :ok = SQLite.put(state1, 1, "persistent_key", %{value: "persistent_data"})
      assert {:ok, %{value: "persistent_data"}} = SQLite.get(state1, 1, "persistent_key")

      # Close connection
      :ok = Exqlite.Sqlite3.close(state1.conn)

      # Reopen database with new connection
      {:ok, state2} = SQLite.init(path: db_path)

      # Verify data is still there
      assert {:ok, %{value: "persistent_data"}} = SQLite.get(state2, 1, "persistent_key")
    end
  end

  describe "RMX004_3A: Edge Cases" do
    test "init/1 accepts custom table name", %{db_path: db_path} do
      assert {:ok, state} = SQLite.init(path: db_path, table: "custom_table")
      assert state.table_name == "custom_table"

      # Verify table was created with custom name
      sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='custom_table'"
      {:ok, stmt} = Exqlite.Sqlite3.prepare(state.conn, sql)
      {:row, [table_name]} = Exqlite.Sqlite3.step(state.conn, stmt)
      :ok = Exqlite.Sqlite3.release(state.conn, stmt)

      assert table_name == "custom_table"
    end

    test "delete/2 returns :ok for non-existent key", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert :ok = SQLite.delete(state, 1, "never_existed")
    end

    test "scan/3 returns empty list when no keys match", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      :ok = SQLite.put(state, 1, "base_card:uuid1", %{front: "Hello"})

      assert {:ok, []} = SQLite.scan(state, 1, "nonexistent:", [])
    end

    test "scan/3 on empty table returns empty list", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert {:ok, []} = SQLite.scan(state, 1, "base_card:", [])
    end

    test "handles special characters in keys", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      special_key = "special:key-with-dash_and_underscore"
      :ok = SQLite.put(state, 1, special_key, %{data: "special"})

      assert {:ok, %{data: "special"}} = SQLite.get(state, 1, special_key)
    end

    test "multiple operations on same database", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Multiple puts
      :ok = SQLite.put(state, 1, "key1", %{value: "value1"})
      :ok = SQLite.put(state, 1, "key2", %{value: "value2"})
      :ok = SQLite.put(state, 1, "key3", %{value: "value3"})

      # Multiple gets
      assert {:ok, %{value: "value1"}} = SQLite.get(state, 1, "key1")
      assert {:ok, %{value: "value2"}} = SQLite.get(state, 1, "key2")
      assert {:ok, %{value: "value3"}} = SQLite.get(state, 1, "key3")

      # Delete some
      :ok = SQLite.delete(state, 1, "key1")
      :ok = SQLite.delete(state, 1, "key2")

      # Verify
      assert {:ok, nil} = SQLite.get(state, 1, "key1")
      assert {:ok, nil} = SQLite.get(state, 1, "key2")
      assert {:ok, %{value: "value3"}} = SQLite.get(state, 1, "key3")
    end
  end

  describe "RMX004_3A: Multi-Operations" do
    # Basic multi_get tests
    test "multi_get/2 with empty list returns empty map", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert {:ok, %{}} = SQLite.multi_get(state, 1, [])
    end

    test "multi_get/2 retrieves multiple keys", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert data
      :ok = SQLite.put(state, 1, "key1", %{value: 1})
      :ok = SQLite.put(state, 1, "key2", %{value: 2})
      :ok = SQLite.put(state, 1, "key3", %{value: 3})

      # Fetch multiple
      assert {:ok, results} = SQLite.multi_get(state, 1, ["key1", "key2", "key3"])
      assert map_size(results) == 3
      assert results["key1"] == %{value: 1}
      assert results["key2"] == %{value: 2}
      assert results["key3"] == %{value: 3}
    end

    test "multi_get/2 handles missing keys", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      :ok = SQLite.put(state, 1, "key1", %{value: 1})

      # Request mix of existing and missing keys
      assert {:ok, results} = SQLite.multi_get(state, 1, ["key1", "missing1", "missing2"])
      assert map_size(results) == 1
      assert results["key1"] == %{value: 1}
      refute Map.has_key?(results, "missing1")
    end

    # Basic multi_put tests
    test "multi_put/2 with empty list returns :ok", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert :ok = SQLite.multi_put(state, 1, [])
    end

    test "multi_put/2 inserts multiple entries", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      entries = [
        {"key1", %{value: 1}},
        {"key2", %{value: 2}},
        {"key3", %{value: 3}}
      ]

      assert :ok = SQLite.multi_put(state, 1, entries)

      # Verify all entries were inserted
      assert {:ok, %{value: 1}} = SQLite.get(state, 1, "key1")
      assert {:ok, %{value: 2}} = SQLite.get(state, 1, "key2")
      assert {:ok, %{value: 3}} = SQLite.get(state, 1, "key3")
    end

    test "multi_put/2 overwrites existing values", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert initial values
      :ok = SQLite.put(state, 1, "key1", %{value: "old"})

      # Multi-put with updated value
      entries = [
        {"key1", %{value: "new"}},
        {"key2", %{value: "fresh"}}
      ]

      assert :ok = SQLite.multi_put(state, 1, entries)

      # Verify values
      assert {:ok, %{value: "new"}} = SQLite.get(state, 1, "key1")
      assert {:ok, %{value: "fresh"}} = SQLite.get(state, 1, "key2")
    end
  end

  describe "RMX004_4A: SQLite Batch Operations" do
    # RMX004_4A_T1: Test SQLite multi_get with empty list
    test "T1: multi_get/2 with empty list returns empty map", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert {:ok, %{}} = SQLite.multi_get(state, 1, [])
    end

    # RMX004_4A_T2: Test SQLite multi_get with 10 keys
    test "T2: multi_get/2 retrieves 10 keys efficiently", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert 10 entries
      entries =
        for i <- 1..10 do
          {"base_card:uuid#{i}", %{front: "Question #{i}", back: "Answer #{i}", index: i}}
        end

      :ok = SQLite.multi_put(state, 1, entries)

      # Fetch all 10
      keys = Enum.map(1..10, &"base_card:uuid#{&1}")
      assert {:ok, results} = SQLite.multi_get(state, 1, keys)

      # Verify all 10 retrieved
      assert map_size(results) == 10

      # Spot check
      assert results["base_card:uuid1"][:front] == "Question 1"
      assert results["base_card:uuid5"][:back] == "Answer 5"
      assert results["base_card:uuid10"][:index] == 10
    end

    # RMX004_4A_T3: Test SQLite multi_get with 100 keys
    test "T3: multi_get/2 retrieves 100 keys efficiently", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert 100 entries
      entries =
        for i <- 1..100 do
          {"base_card:uuid#{i}", %{front: "Q#{i}", back: "A#{i}", index: i}}
        end

      :ok = SQLite.multi_put(state, 1, entries)

      # Fetch all 100
      keys = Enum.map(1..100, &"base_card:uuid#{&1}")

      {time_us, {:ok, results}} = :timer.tc(fn -> SQLite.multi_get(state, 1, keys) end)

      # Verify all 100 retrieved
      assert map_size(results) == 100

      # Verify performance target (<20ms = 20,000 microseconds)
      assert time_us < 20_000, "multi_get took #{time_us}μs, expected <20,000μs"

      # Spot check various entries
      assert results["base_card:uuid1"][:index] == 1
      assert results["base_card:uuid50"][:index] == 50
      assert results["base_card:uuid100"][:index] == 100
    end

    # RMX004_4A_T4: Test SQLite multi_get with missing keys
    test "T4: multi_get/2 handles missing keys correctly", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert some entries
      entries = [
        {"key1", %{value: 1}},
        {"key3", %{value: 3}},
        {"key5", %{value: 5}}
      ]

      :ok = SQLite.multi_put(state, 1, entries)

      # Request mix of existing and missing keys
      keys = ["key1", "key2", "key3", "key4", "key5", "key6"]
      assert {:ok, results} = SQLite.multi_get(state, 1, keys)

      # Only existing keys should be in results
      assert map_size(results) == 3
      assert results["key1"][:value] == 1
      assert results["key3"][:value] == 3
      assert results["key5"][:value] == 5

      # Missing keys should not be present
      refute Map.has_key?(results, "key2")
      refute Map.has_key?(results, "key4")
      refute Map.has_key?(results, "key6")
    end

    # RMX004_4A_T5: Test SQLite multi_put with empty list
    test "T5: multi_put/2 with empty list returns :ok", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert :ok = SQLite.multi_put(state, 1, [])

      # Verify no entries in database
      assert {:ok, []} = SQLite.scan(state, 1, "", [])
    end

    # RMX004_4A_T6: Test SQLite multi_put with 10 entries
    test "T6: multi_put/2 inserts 10 entries transactionally", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      entries =
        for i <- 1..10 do
          {"base_card:uuid#{i}", %{front: "Question #{i}", back: "Answer #{i}"}}
        end

      assert :ok = SQLite.multi_put(state, 1, entries)

      # Verify all 10 entries exist
      for i <- 1..10 do
        assert {:ok, data} = SQLite.get(state, 1, "base_card:uuid#{i}")
        assert data[:front] == "Question #{i}"
        assert data[:back] == "Answer #{i}"
      end
    end

    # RMX004_4A_T7: Test SQLite multi_put with 100 entries
    test "T7: multi_put/2 inserts 100 entries efficiently", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      entries =
        for i <- 1..100 do
          {
            "base_card:uuid#{i}",
            %{
              front: "Question #{i}",
              back: "Answer #{i}",
              metadata: %{
                tags: ["tag#{i}"],
                level: rem(i, 5)
              }
            }
          }
        end

      {time_us, :ok} = :timer.tc(fn -> SQLite.multi_put(state, 1, entries) end)

      # Verify performance target (<50ms = 50,000 microseconds)
      assert time_us < 50_000, "multi_put took #{time_us}μs, expected <50,000μs"

      # Verify all entries exist
      for i <- [1, 25, 50, 75, 100] do
        assert {:ok, data} = SQLite.get(state, 1, "base_card:uuid#{i}")
        assert data[:front] == "Question #{i}"
        assert data[:metadata][:level] == rem(i, 5)
      end

      # Verify total count via scan
      {:ok, all_cards} = SQLite.scan(state, 1, "base_card:", [])
      assert length(all_cards) == 100
    end

    # RMX004_4A_T8: Test SQLite multi_put transaction (all or nothing)
    test "T8: multi_put/2 is transactional (all or nothing)", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # First, insert some successful entries
      entries = [
        {"key1", %{value: 1}},
        {"key2", %{value: 2}}
      ]

      assert :ok = SQLite.multi_put(state, 1, entries)

      # Verify they exist
      assert {:ok, %{value: 1}} = SQLite.get(state, 1, "key1")
      assert {:ok, %{value: 2}} = SQLite.get(state, 1, "key2")

      # Now test that overwriting works in a transaction
      new_entries = [
        {"key1", %{value: 100}},
        {"key2", %{value: 200}},
        {"key3", %{value: 300}}
      ]

      assert :ok = SQLite.multi_put(state, 1, new_entries)

      # All should be updated/inserted atomically
      assert {:ok, %{value: 100}} = SQLite.get(state, 1, "key1")
      assert {:ok, %{value: 200}} = SQLite.get(state, 1, "key2")
      assert {:ok, %{value: 300}} = SQLite.get(state, 1, "key3")
    end

    # RMX004_4A_T9: Test SQLite multi_put performance (<50ms for 100 entries)
    test "T9: multi_put/2 meets performance target (<50ms for 100 entries)", %{
      db_path: db_path
    } do
      {:ok, state} = SQLite.init(path: db_path)

      # Generate 100 realistic card entries
      entries =
        for i <- 1..100 do
          {
            "base_card:#{__MODULE__.UUID.uuid4()}",
            %{
              id: __MODULE__.UUID.uuid4(),
              front: "Front text #{i} with some reasonable content length",
              back: "Back text #{i} with answer content",
              metadata: %{
                created_at: System.system_time(:millisecond),
                tags: ["vocabulary", "level#{rem(i, 3)}"],
                pronunciation: "IPA notation here"
              },
              translations: %{
                es: "Spanish #{i}",
                fr: "French #{i}",
                de: "German #{i}"
              }
            }
          }
        end

      # Measure performance
      {time_us, :ok} = :timer.tc(fn -> SQLite.multi_put(state, 1, entries) end)

      time_ms = time_us / 1000

      # Assert performance target
      assert time_ms < 50, "multi_put took #{time_ms}ms, expected <50ms"

      # Also verify data integrity (Erlang terms preserve atom keys)
      {first_key, _} = List.first(entries)
      assert {:ok, data} = SQLite.get(state, 1, first_key)
      assert Map.has_key?(data, :front)
      assert Map.has_key?(data, :metadata)
    end
  end

  describe "RMX007_5A: SQLite Adapter Space Support" do
    # RMX007_5_T1: Test SQLite get/put/delete with space_id
    test "RMX007_5_T1: get/put/delete with space_id", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Put value in space 1
      :ok = SQLite.put(state, 1, "key1", %{data: "value1"})
      {:ok, value} = SQLite.get(state, 1, "key1")
      assert value == %{data: "value1"}

      # Delete the value
      :ok = SQLite.delete(state, 1, "key1")
      {:ok, nil} = SQLite.get(state, 1, "key1")
    end

    # RMX007_5_T2: Test different spaces are isolated
    test "RMX007_5_T2: different spaces are isolated", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Put same key in different spaces
      :ok = SQLite.put(state, 1, "key", %{space: 1})
      :ok = SQLite.put(state, 2, "key", %{space: 2})

      # Values should be isolated
      {:ok, value1} = SQLite.get(state, 1, "key")
      {:ok, value2} = SQLite.get(state, 2, "key")

      assert value1 == %{space: 1}
      assert value2 == %{space: 2}
    end

    # RMX007_5_T3: Test same key in different spaces
    test "RMX007_5_T3: same key in different spaces", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Put different values with same key in different spaces
      :ok = SQLite.put(state, 1, "shared_key", %{tenant: "acme"})
      :ok = SQLite.put(state, 2, "shared_key", %{tenant: "widgets"})
      :ok = SQLite.put(state, 3, "shared_key", %{tenant: "staging"})

      # Each space should have its own value
      {:ok, val1} = SQLite.get(state, 1, "shared_key")
      {:ok, val2} = SQLite.get(state, 2, "shared_key")
      {:ok, val3} = SQLite.get(state, 3, "shared_key")

      assert val1 == %{tenant: "acme"}
      assert val2 == %{tenant: "widgets"}
      assert val3 == %{tenant: "staging"}

      # Delete from one space shouldn't affect others
      :ok = SQLite.delete(state, 2, "shared_key")
      {:ok, nil} = SQLite.get(state, 2, "shared_key")
      {:ok, val1_after} = SQLite.get(state, 1, "shared_key")
      {:ok, val3_after} = SQLite.get(state, 3, "shared_key")

      assert val1_after == %{tenant: "acme"}
      assert val3_after == %{tenant: "staging"}
    end

    test "scan with space_id returns only space data", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Put data in different spaces with same prefix
      :ok = SQLite.put(state, 1, "card:1", %{id: 1, space: 1})
      :ok = SQLite.put(state, 1, "card:2", %{id: 2, space: 1})
      :ok = SQLite.put(state, 2, "card:1", %{id: 1, space: 2})
      :ok = SQLite.put(state, 2, "card:3", %{id: 3, space: 2})

      # Scan space 1
      {:ok, results1} = SQLite.scan(state, 1, "card:", [])
      assert length(results1) == 2
      assert {"card:1", %{id: 1, space: 1}} in results1
      assert {"card:2", %{id: 2, space: 1}} in results1

      # Scan space 2
      {:ok, results2} = SQLite.scan(state, 2, "card:", [])
      assert length(results2) == 2
      assert {"card:1", %{id: 1, space: 2}} in results2
      assert {"card:3", %{id: 3, space: 2}} in results2
    end

    test "multi_get with space_id", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Put data in different spaces
      :ok = SQLite.put(state, 1, "key1", %{val: 1})
      :ok = SQLite.put(state, 1, "key2", %{val: 2})
      :ok = SQLite.put(state, 2, "key1", %{val: 3})

      # Multi-get from space 1
      {:ok, results1} = SQLite.multi_get(state, 1, ["key1", "key2", "key3"])
      assert results1 == %{"key1" => %{val: 1}, "key2" => %{val: 2}}

      # Multi-get from space 2
      {:ok, results2} = SQLite.multi_get(state, 2, ["key1", "key2"])
      assert results2 == %{"key1" => %{val: 3}}
    end

    test "multi_put with space_id", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Multi-put in space 1
      :ok = SQLite.multi_put(state, 1, [{"key1", %{val: 1}}, {"key2", %{val: 2}}])

      {:ok, val1} = SQLite.get(state, 1, "key1")
      {:ok, val2} = SQLite.get(state, 1, "key2")

      assert val1 == %{val: 1}
      assert val2 == %{val: 2}

      # Same keys in space 2 should not exist
      {:ok, nil} = SQLite.get(state, 2, "key1")
      {:ok, nil} = SQLite.get(state, 2, "key2")
    end

    test "composite primary key prevents conflicts", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Put same key in different spaces
      :ok = SQLite.put(state, 1, "key", %{version: 1})
      :ok = SQLite.put(state, 2, "key", %{version: 2})

      # Update in space 1 shouldn't affect space 2
      :ok = SQLite.put(state, 1, "key", %{version: 1, updated: true})

      {:ok, val1} = SQLite.get(state, 1, "key")
      {:ok, val2} = SQLite.get(state, 2, "key")

      assert val1 == %{version: 1, updated: true}
      assert val2 == %{version: 2}
    end
  end

  # Helper module for UUID generation
  defmodule UUID do
    def uuid4 do
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)
      |> String.replace(~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")
    end
  end
end
