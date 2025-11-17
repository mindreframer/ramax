defmodule PState.Adapters.SQLiteTest do
  use ExUnit.Case, async: true
  alias PState.Adapters.SQLite

  setup do
    # Create unique DB file for each test
    db_path = "/tmp/pstate_test_#{:rand.uniform(1_000_000)}.db"

    on_exit(fn ->
      # Clean up database file
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

      # Verify schema has key, value, updated_at columns
      assert create_sql =~ "key TEXT PRIMARY KEY"
      assert create_sql =~ "value TEXT NOT NULL"
      assert create_sql =~ "updated_at INTEGER"
    end

    # RMX004_3A_T4: Test index creation
    test "T4: init/1 creates index on updated_at", %{db_path: db_path} do
      assert {:ok, state} = SQLite.init(path: db_path)

      # Query indexes
      sql = "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_updated_at'"
      {:ok, stmt} = Exqlite.Sqlite3.prepare(state.conn, sql)
      {:row, [index_name]} = Exqlite.Sqlite3.step(state.conn, stmt)
      :ok = Exqlite.Sqlite3.release(state.conn, stmt)

      assert index_name == "idx_updated_at"
    end

    # RMX004_3A_T5: Test put/get single value
    test "T5: put/3 and get/2 work with single value", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      data = %{front: "Hello", back: "Hola"}
      assert :ok = SQLite.put(state, "base_card:uuid1", data)

      assert {:ok, retrieved} = SQLite.get(state, "base_card:uuid1")
      assert retrieved == %{"front" => "Hello", "back" => "Hola"}
    end

    # RMX004_3A_T6: Test put overwrites existing
    test "T6: put/3 overwrites existing value", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert initial value
      :ok = SQLite.put(state, "key1", %{value: "first"})
      assert {:ok, %{"value" => "first"}} = SQLite.get(state, "key1")

      # Overwrite
      :ok = SQLite.put(state, "key1", %{value: "second"})
      assert {:ok, %{"value" => "second"}} = SQLite.get(state, "key1")
    end

    # RMX004_3A_T7: Test get missing key
    test "T7: get/2 returns {:ok, nil} for missing key", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert {:ok, nil} = SQLite.get(state, "nonexistent_key")
      assert {:ok, nil} = SQLite.get(state, "base_card:missing")
    end

    # RMX004_3A_T8: Test delete removes value
    test "T8: delete/2 removes value", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert and verify
      :ok = SQLite.put(state, "to_delete", %{data: "value"})
      assert {:ok, %{"data" => "value"}} = SQLite.get(state, "to_delete")

      # Delete
      assert :ok = SQLite.delete(state, "to_delete")

      # Verify it's gone
      assert {:ok, nil} = SQLite.get(state, "to_delete")
    end

    # RMX004_3A_T9: Test scan by prefix
    test "T9: scan/3 returns entries matching prefix", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert multiple entries
      :ok = SQLite.put(state, "base_card:uuid1", %{front: "Hello"})
      :ok = SQLite.put(state, "base_card:uuid2", %{front: "Goodbye"})
      :ok = SQLite.put(state, "base_deck:uuid3", %{title: "Spanish 101"})
      :ok = SQLite.put(state, "other:uuid4", %{data: "something"})

      # Scan for base_card prefix
      assert {:ok, card_results} = SQLite.scan(state, "base_card:", [])
      assert length(card_results) == 2

      card_keys = Enum.map(card_results, fn {key, _value} -> key end)
      assert "base_card:uuid1" in card_keys
      assert "base_card:uuid2" in card_keys

      # Verify values are decoded
      {_key, value} = List.first(card_results)
      assert is_map(value)
      assert Map.has_key?(value, "front")
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

      :ok = SQLite.put(state, "base_card:complex", complex_data)
      assert {:ok, retrieved} = SQLite.get(state, "base_card:complex")

      # Verify structure is preserved (keys become strings due to JSON)
      assert retrieved["id"] == "550e8400"
      assert retrieved["front"] == "Hello"
      assert retrieved["metadata"]["pronunciation"] == "həˈloʊ"
      assert retrieved["metadata"]["tags"] == ["greeting", "common"]
      assert retrieved["metadata"]["level"] == 1
      assert retrieved["translations"]["es"] == "Hola"
    end

    # RMX004_3A_T11: Test persistence (close/reopen DB)
    test "T11: data persists across connection close/reopen", %{db_path: db_path} do
      # First connection - insert data
      {:ok, state1} = SQLite.init(path: db_path)
      :ok = SQLite.put(state1, "persistent_key", %{value: "persistent_data"})
      assert {:ok, %{"value" => "persistent_data"}} = SQLite.get(state1, "persistent_key")

      # Close connection
      :ok = Exqlite.Sqlite3.close(state1.conn)

      # Reopen database with new connection
      {:ok, state2} = SQLite.init(path: db_path)

      # Verify data is still there
      assert {:ok, %{"value" => "persistent_data"}} = SQLite.get(state2, "persistent_key")
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

      assert :ok = SQLite.delete(state, "never_existed")
    end

    test "scan/3 returns empty list when no keys match", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      :ok = SQLite.put(state, "base_card:uuid1", %{front: "Hello"})

      assert {:ok, []} = SQLite.scan(state, "nonexistent:", [])
    end

    test "scan/3 on empty table returns empty list", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert {:ok, []} = SQLite.scan(state, "base_card:", [])
    end

    test "handles special characters in keys", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      special_key = "special:key-with-dash_and_underscore"
      :ok = SQLite.put(state, special_key, %{data: "special"})

      assert {:ok, %{"data" => "special"}} = SQLite.get(state, special_key)
    end

    test "multiple operations on same database", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Multiple puts
      :ok = SQLite.put(state, "key1", %{value: "value1"})
      :ok = SQLite.put(state, "key2", %{value: "value2"})
      :ok = SQLite.put(state, "key3", %{value: "value3"})

      # Multiple gets
      assert {:ok, %{"value" => "value1"}} = SQLite.get(state, "key1")
      assert {:ok, %{"value" => "value2"}} = SQLite.get(state, "key2")
      assert {:ok, %{"value" => "value3"}} = SQLite.get(state, "key3")

      # Delete some
      :ok = SQLite.delete(state, "key1")
      :ok = SQLite.delete(state, "key2")

      # Verify
      assert {:ok, nil} = SQLite.get(state, "key1")
      assert {:ok, nil} = SQLite.get(state, "key2")
      assert {:ok, %{"value" => "value3"}} = SQLite.get(state, "key3")
    end
  end

  describe "RMX004_3A: Multi-Operations" do
    # Basic multi_get tests
    test "multi_get/2 with empty list returns empty map", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert {:ok, %{}} = SQLite.multi_get(state, [])
    end

    test "multi_get/2 retrieves multiple keys", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert data
      :ok = SQLite.put(state, "key1", %{value: 1})
      :ok = SQLite.put(state, "key2", %{value: 2})
      :ok = SQLite.put(state, "key3", %{value: 3})

      # Fetch multiple
      assert {:ok, results} = SQLite.multi_get(state, ["key1", "key2", "key3"])
      assert map_size(results) == 3
      assert results["key1"] == %{"value" => 1}
      assert results["key2"] == %{"value" => 2}
      assert results["key3"] == %{"value" => 3}
    end

    test "multi_get/2 handles missing keys", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      :ok = SQLite.put(state, "key1", %{value: 1})

      # Request mix of existing and missing keys
      assert {:ok, results} = SQLite.multi_get(state, ["key1", "missing1", "missing2"])
      assert map_size(results) == 1
      assert results["key1"] == %{"value" => 1}
      refute Map.has_key?(results, "missing1")
    end

    # Basic multi_put tests
    test "multi_put/2 with empty list returns :ok", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      assert :ok = SQLite.multi_put(state, [])
    end

    test "multi_put/2 inserts multiple entries", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      entries = [
        {"key1", %{value: 1}},
        {"key2", %{value: 2}},
        {"key3", %{value: 3}}
      ]

      assert :ok = SQLite.multi_put(state, entries)

      # Verify all entries were inserted
      assert {:ok, %{"value" => 1}} = SQLite.get(state, "key1")
      assert {:ok, %{"value" => 2}} = SQLite.get(state, "key2")
      assert {:ok, %{"value" => 3}} = SQLite.get(state, "key3")
    end

    test "multi_put/2 overwrites existing values", %{db_path: db_path} do
      {:ok, state} = SQLite.init(path: db_path)

      # Insert initial values
      :ok = SQLite.put(state, "key1", %{value: "old"})

      # Multi-put with updated value
      entries = [
        {"key1", %{value: "new"}},
        {"key2", %{value: "fresh"}}
      ]

      assert :ok = SQLite.multi_put(state, entries)

      # Verify values
      assert {:ok, %{"value" => "new"}} = SQLite.get(state, "key1")
      assert {:ok, %{"value" => "fresh"}} = SQLite.get(state, "key2")
    end
  end
end
