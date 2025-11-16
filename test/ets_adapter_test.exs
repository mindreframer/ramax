defmodule PState.Adapters.ETSTest do
  use ExUnit.Case, async: true
  alias PState.Adapters.ETS

  describe "RMX001_2A: ETS Adapter Implementation" do
    # RMX001_2A_T1: Test ETS adapter init creates table
    test "T1: init/1 creates ETS table with default name" do
      assert {:ok, state} = ETS.init([])
      assert is_reference(state.table)

      # Verify table exists and has correct properties
      info = :ets.info(state.table)
      assert info != :undefined
      assert info[:type] == :set
      assert info[:protection] == :public
      assert info[:read_concurrency] == true
    end

    test "T1b: init/1 creates ETS table with custom name" do
      table_name = :"test_table_#{:rand.uniform(1000)}"
      assert {:ok, state} = ETS.init(table_name: table_name)
      assert is_reference(state.table)

      info = :ets.info(state.table)
      assert info != :undefined
    end

    # RMX001_2A_T2: Test ETS get returns nil for missing key
    test "T2: get/2 returns {:ok, nil} for missing key" do
      {:ok, state} = ETS.init([])

      assert {:ok, nil} = ETS.get(state, "nonexistent_key")
      assert {:ok, nil} = ETS.get(state, "base_card:uuid")
    end

    # RMX001_2A_T3: Test ETS put stores value
    test "T3: put/3 stores value successfully" do
      {:ok, state} = ETS.init([])

      assert :ok = ETS.put(state, "test_key", "test_value")
      assert :ok = ETS.put(state, "base_card:uuid", %{front: "Hello", back: "Hola"})

      # Verify values are actually in ETS
      assert [{_, "test_value"}] = :ets.lookup(state.table, "test_key")
    end

    # RMX001_2A_T4: Test ETS get retrieves stored value
    test "T4: get/2 retrieves stored value" do
      {:ok, state} = ETS.init([])

      # Store simple value
      :ok = ETS.put(state, "simple_key", "simple_value")
      assert {:ok, "simple_value"} = ETS.get(state, "simple_key")

      # Store complex value (map)
      card_data = %{
        id: "550e8400",
        front: "Hello",
        back: "Hola",
        metadata: %{pronunciation: "həˈloʊ"}
      }

      :ok = ETS.put(state, "base_card:550e8400", card_data)
      assert {:ok, ^card_data} = ETS.get(state, "base_card:550e8400")
    end

    # RMX001_2A_T5: Test ETS delete removes key
    test "T5: delete/2 removes key" do
      {:ok, state} = ETS.init([])

      # Store a value
      :ok = ETS.put(state, "to_delete", "value")
      assert {:ok, "value"} = ETS.get(state, "to_delete")

      # Delete it
      assert :ok = ETS.delete(state, "to_delete")
    end

    # RMX001_2A_T6: Test ETS get returns nil after delete
    test "T6: get/2 returns {:ok, nil} after delete" do
      {:ok, state} = ETS.init([])

      # Store and verify
      :ok = ETS.put(state, "key_to_delete", "value")
      assert {:ok, "value"} = ETS.get(state, "key_to_delete")

      # Delete
      :ok = ETS.delete(state, "key_to_delete")

      # Verify it's gone
      assert {:ok, nil} = ETS.get(state, "key_to_delete")
    end

    test "T6b: delete/2 returns :ok even if key doesn't exist" do
      {:ok, state} = ETS.init([])

      # Delete non-existent key should still return :ok
      assert :ok = ETS.delete(state, "never_existed")
    end

    # RMX001_2A_T7: Test ETS scan with prefix filter
    test "T7: scan/3 returns entries matching prefix" do
      {:ok, state} = ETS.init([])

      # Store multiple entities
      :ok = ETS.put(state, "base_card:uuid1", %{front: "Hello"})
      :ok = ETS.put(state, "base_card:uuid2", %{front: "Goodbye"})
      :ok = ETS.put(state, "base_deck:uuid3", %{title: "Spanish 101"})
      :ok = ETS.put(state, "base_deck:uuid4", %{title: "French 101"})
      :ok = ETS.put(state, "other:uuid5", %{data: "something"})

      # Scan for base_card prefix
      assert {:ok, card_results} = ETS.scan(state, "base_card:", [])
      assert length(card_results) == 2

      card_keys = Enum.map(card_results, fn {key, _value} -> key end)
      assert "base_card:uuid1" in card_keys
      assert "base_card:uuid2" in card_keys

      # Scan for base_deck prefix
      assert {:ok, deck_results} = ETS.scan(state, "base_deck:", [])
      assert length(deck_results) == 2

      deck_keys = Enum.map(deck_results, fn {key, _value} -> key end)
      assert "base_deck:uuid3" in deck_keys
      assert "base_deck:uuid4" in deck_keys

      # Verify values are included
      {_key, value} = List.first(card_results)
      assert is_map(value)
      assert Map.has_key?(value, :front)
    end

    # RMX001_2A_T8: Test ETS scan returns empty list for no matches
    test "T8: scan/3 returns empty list when no keys match prefix" do
      {:ok, state} = ETS.init([])

      # Store some data
      :ok = ETS.put(state, "base_card:uuid1", %{front: "Hello"})
      :ok = ETS.put(state, "base_deck:uuid2", %{title: "Deck"})

      # Scan for non-existent prefix
      assert {:ok, []} = ETS.scan(state, "nonexistent:", [])
      assert {:ok, []} = ETS.scan(state, "missing_prefix:", [])
    end

    test "T8b: scan/3 on empty table returns empty list" do
      {:ok, state} = ETS.init([])

      # Scan empty table
      assert {:ok, []} = ETS.scan(state, "base_card:", [])
    end
  end

  describe "RMX001_2A: Edge Cases and Error Handling" do
    test "put/3 handles nil values" do
      {:ok, state} = ETS.init([])

      assert :ok = ETS.put(state, "nil_key", nil)
      assert {:ok, nil} = ETS.get(state, "nil_key")
    end

    test "put/3 overwrites existing values" do
      {:ok, state} = ETS.init([])

      :ok = ETS.put(state, "key", "value1")
      assert {:ok, "value1"} = ETS.get(state, "key")

      :ok = ETS.put(state, "key", "value2")
      assert {:ok, "value2"} = ETS.get(state, "key")
    end

    test "scan/3 handles special characters in prefix" do
      {:ok, state} = ETS.init([])

      :ok = ETS.put(state, "special:key-with-dash", "value1")
      :ok = ETS.put(state, "special:key_with_underscore", "value2")

      assert {:ok, results} = ETS.scan(state, "special:", [])
      assert length(results) == 2
    end

    test "multiple operations on same table" do
      {:ok, state} = ETS.init([])

      # Multiple puts
      :ok = ETS.put(state, "key1", "value1")
      :ok = ETS.put(state, "key2", "value2")
      :ok = ETS.put(state, "key3", "value3")

      # Multiple gets
      assert {:ok, "value1"} = ETS.get(state, "key1")
      assert {:ok, "value2"} = ETS.get(state, "key2")
      assert {:ok, "value3"} = ETS.get(state, "key3")

      # Multiple deletes
      :ok = ETS.delete(state, "key1")
      :ok = ETS.delete(state, "key2")

      # Verify
      assert {:ok, nil} = ETS.get(state, "key1")
      assert {:ok, nil} = ETS.get(state, "key2")
      assert {:ok, "value3"} = ETS.get(state, "key3")
    end
  end
end
