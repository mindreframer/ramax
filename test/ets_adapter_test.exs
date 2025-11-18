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

      assert {:ok, nil} = ETS.get(state, 1, "nonexistent_key")
      assert {:ok, nil} = ETS.get(state, 1, "base_card:uuid")
    end

    # RMX001_2A_T3: Test ETS put stores value successfully
    test "T3: put/3 stores value successfully" do
      {:ok, state} = ETS.init([])

      assert :ok = ETS.put(state, 1, "test_key", "test_value")
      assert :ok = ETS.put(state, 1, "base_card:uuid", %{front: "Hello", back: "Hola"})

      # Verify values are actually in ETS with composite keys
      assert [{{1, "test_key"}, "test_value"}] = :ets.lookup(state.table, {1, "test_key"})
    end

    # RMX001_2A_T4: Test ETS get retrieves stored value
    test "T4: get/2 retrieves stored value" do
      {:ok, state} = ETS.init([])

      # Store simple value
      :ok = ETS.put(state, 1, "simple_key", "simple_value")
      assert {:ok, "simple_value"} = ETS.get(state, 1, "simple_key")

      # Store complex value (map)
      card_data = %{
        id: "550e8400",
        front: "Hello",
        back: "Hola",
        metadata: %{pronunciation: "həˈloʊ"}
      }

      :ok = ETS.put(state, 1, "base_card:550e8400", card_data)
      assert {:ok, ^card_data} = ETS.get(state, 1, "base_card:550e8400")
    end

    # RMX001_2A_T5: Test ETS delete removes key
    test "T5: delete/2 removes key" do
      {:ok, state} = ETS.init([])

      # Store a value
      :ok = ETS.put(state, 1, "to_delete", "value")
      assert {:ok, "value"} = ETS.get(state, 1, "to_delete")

      # Delete it
      assert :ok = ETS.delete(state, 1, "to_delete")
    end

    # RMX001_2A_T6: Test ETS get returns nil after delete
    test "T6: get/2 returns {:ok, nil} after delete" do
      {:ok, state} = ETS.init([])

      # Store and verify
      :ok = ETS.put(state, 1, "key_to_delete", "value")
      assert {:ok, "value"} = ETS.get(state, 1, "key_to_delete")

      # Delete
      :ok = ETS.delete(state, 1, "key_to_delete")

      # Verify it's gone
      assert {:ok, nil} = ETS.get(state, 1, "key_to_delete")
    end

    test "T6b: delete/2 returns :ok even if key doesn't exist" do
      {:ok, state} = ETS.init([])

      # Delete non-existent key should still return :ok
      assert :ok = ETS.delete(state, 1, "never_existed")
    end

    # RMX001_2A_T7: Test ETS scan with prefix filter
    test "T7: scan/3 returns entries matching prefix" do
      {:ok, state} = ETS.init([])

      # Store multiple entities
      :ok = ETS.put(state, 1, "base_card:uuid1", %{front: "Hello"})
      :ok = ETS.put(state, 1, "base_card:uuid2", %{front: "Goodbye"})
      :ok = ETS.put(state, 1, "base_deck:uuid3", %{title: "Spanish 101"})
      :ok = ETS.put(state, 1, "base_deck:uuid4", %{title: "French 101"})
      :ok = ETS.put(state, 1, "other:uuid5", %{data: "something"})

      # Scan for base_card prefix
      assert {:ok, card_results} = ETS.scan(state, 1, "base_card:", [])
      assert length(card_results) == 2

      card_keys = Enum.map(card_results, fn {key, _value} -> key end)
      assert "base_card:uuid1" in card_keys
      assert "base_card:uuid2" in card_keys

      # Scan for base_deck prefix
      assert {:ok, deck_results} = ETS.scan(state, 1, "base_deck:", [])
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
      :ok = ETS.put(state, 1, "base_card:uuid1", %{front: "Hello"})
      :ok = ETS.put(state, 1, "base_deck:uuid2", %{title: "Deck"})

      # Scan for non-existent prefix
      assert {:ok, []} = ETS.scan(state, 1, "nonexistent:", [])
      assert {:ok, []} = ETS.scan(state, 1, "missing_prefix:", [])
    end

    test "T8b: scan/3 on empty table returns empty list" do
      {:ok, state} = ETS.init([])

      # Scan empty table
      assert {:ok, []} = ETS.scan(state, 1, "base_card:", [])
    end
  end

  describe "RMX007_5A: ETS Adapter Space Support" do
    # RMX007_5_T4: Test ETS get/put/delete with space_id
    test "RMX007_5_T4: get/put/delete with space_id" do
      {:ok, state} = ETS.init([])

      # Put value in space 1
      :ok = ETS.put(state, 1, "key1", %{data: "value1"})
      {:ok, value} = ETS.get(state, 1, "key1")
      assert value == %{data: "value1"}

      # Delete the value
      :ok = ETS.delete(state, 1, "key1")
      {:ok, nil} = ETS.get(state, 1, "key1")
    end

    # RMX007_5_T5: Test different spaces are isolated
    test "RMX007_5_T5: different spaces are isolated" do
      {:ok, state} = ETS.init([])

      # Put same key in different spaces
      :ok = ETS.put(state, 1, "key", %{space: 1})
      :ok = ETS.put(state, 2, "key", %{space: 2})

      # Values should be isolated
      {:ok, value1} = ETS.get(state, 1, "key")
      {:ok, value2} = ETS.get(state, 2, "key")

      assert value1 == %{space: 1}
      assert value2 == %{space: 2}
    end

    test "composite key isolation" do
      {:ok, state} = ETS.init([])

      # Put different values with same key in different spaces
      :ok = ETS.put(state, 1, "shared_key", %{tenant: "acme"})
      :ok = ETS.put(state, 2, "shared_key", %{tenant: "widgets"})
      :ok = ETS.put(state, 3, "shared_key", %{tenant: "staging"})

      # Each space should have its own value
      {:ok, val1} = ETS.get(state, 1, "shared_key")
      {:ok, val2} = ETS.get(state, 2, "shared_key")
      {:ok, val3} = ETS.get(state, 3, "shared_key")

      assert val1 == %{tenant: "acme"}
      assert val2 == %{tenant: "widgets"}
      assert val3 == %{tenant: "staging"}

      # Delete from one space shouldn't affect others
      :ok = ETS.delete(state, 2, "shared_key")
      {:ok, nil} = ETS.get(state, 2, "shared_key")
      {:ok, val1_after} = ETS.get(state, 1, "shared_key")
      {:ok, val3_after} = ETS.get(state, 3, "shared_key")

      assert val1_after == %{tenant: "acme"}
      assert val3_after == %{tenant: "staging"}
    end

    test "scan with space_id returns only space data" do
      {:ok, state} = ETS.init([])

      # Put data in different spaces with same prefix
      :ok = ETS.put(state, 1, "card:1", %{id: 1, space: 1})
      :ok = ETS.put(state, 1, "card:2", %{id: 2, space: 1})
      :ok = ETS.put(state, 2, "card:1", %{id: 1, space: 2})
      :ok = ETS.put(state, 2, "card:3", %{id: 3, space: 2})

      # Scan space 1
      {:ok, results1} = ETS.scan(state, 1, "card:", [])
      assert length(results1) == 2
      assert {"card:1", %{id: 1, space: 1}} in results1
      assert {"card:2", %{id: 2, space: 1}} in results1

      # Scan space 2
      {:ok, results2} = ETS.scan(state, 2, "card:", [])
      assert length(results2) == 2
      assert {"card:1", %{id: 1, space: 2}} in results2
      assert {"card:3", %{id: 3, space: 2}} in results2
    end

    test "multi_get with space_id" do
      {:ok, state} = ETS.init([])

      # Put data in different spaces
      :ok = ETS.put(state, 1, "key1", %{val: 1})
      :ok = ETS.put(state, 1, "key2", %{val: 2})
      :ok = ETS.put(state, 2, "key1", %{val: 3})

      # Multi-get from space 1
      {:ok, results1} = ETS.multi_get(state, 1, ["key1", "key2", "key3"])
      assert results1 == %{"key1" => %{val: 1}, "key2" => %{val: 2}}

      # Multi-get from space 2
      {:ok, results2} = ETS.multi_get(state, 2, ["key1", "key2"])
      assert results2 == %{"key1" => %{val: 3}}
    end

    test "multi_put with space_id" do
      {:ok, state} = ETS.init([])

      # Multi-put in space 1
      :ok = ETS.multi_put(state, 1, [{"key1", %{val: 1}}, {"key2", %{val: 2}}])

      {:ok, val1} = ETS.get(state, 1, "key1")
      {:ok, val2} = ETS.get(state, 1, "key2")

      assert val1 == %{val: 1}
      assert val2 == %{val: 2}

      # Same keys in space 2 should not exist
      {:ok, nil} = ETS.get(state, 2, "key1")
      {:ok, nil} = ETS.get(state, 2, "key2")
    end
  end

  describe "RMX001_2A: Edge Cases and Error Handling" do
    test "put/3 handles nil values" do
      {:ok, state} = ETS.init([])

      assert :ok = ETS.put(state, 1, "nil_key", nil)
      assert {:ok, nil} = ETS.get(state, 1, "nil_key")
    end

    test "put/3 overwrites existing values" do
      {:ok, state} = ETS.init([])

      :ok = ETS.put(state, 1, "key", "value1")
      assert {:ok, "value1"} = ETS.get(state, 1, "key")

      :ok = ETS.put(state, 1, "key", "value2")
      assert {:ok, "value2"} = ETS.get(state, 1, "key")
    end

    test "scan/3 handles special characters in prefix" do
      {:ok, state} = ETS.init([])

      :ok = ETS.put(state, 1, "special:key-with-dash", "value1")
      :ok = ETS.put(state, 1, "special:key_with_underscore", "value2")

      assert {:ok, results} = ETS.scan(state, 1, "special:", [])
      assert length(results) == 2
    end

    test "multiple operations on same table" do
      {:ok, state} = ETS.init([])

      # Multiple puts
      :ok = ETS.put(state, 1, "key1", "value1")
      :ok = ETS.put(state, 1, "key2", "value2")
      :ok = ETS.put(state, 1, "key3", "value3")

      # Multiple gets
      assert {:ok, "value1"} = ETS.get(state, 1, "key1")
      assert {:ok, "value2"} = ETS.get(state, 1, "key2")
      assert {:ok, "value3"} = ETS.get(state, 1, "key3")

      # Multiple deletes
      :ok = ETS.delete(state, 1, "key1")
      :ok = ETS.delete(state, 1, "key2")

      # Verify
      assert {:ok, nil} = ETS.get(state, 1, "key1")
      assert {:ok, nil} = ETS.get(state, 1, "key2")
      assert {:ok, "value3"} = ETS.get(state, 1, "key3")
    end
  end
end
