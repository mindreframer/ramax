defmodule PState.MultiOperationsTest do
  use ExUnit.Case, async: true
  alias PState.Adapters.ETS

  describe "RMX004_2A: Adapter Multi-Operations" do
    # RMX004_2A_T1: Test multi_get with empty list
    test "T1: multi_get/2 with empty list returns empty map" do
      {:ok, state} = ETS.init([])

      assert {:ok, results} = ETS.multi_get(state, 1, [])
      assert results == %{}
    end

    # RMX004_2A_T2: Test multi_get with single key
    test "T2: multi_get/2 with single key returns map with that key" do
      {:ok, state} = ETS.init([])

      # Put a value
      :ok = ETS.put(state, 1, "base_card:uuid1", %{front: "Hello", back: "Hola"})

      # Multi-get single key
      assert {:ok, results} = ETS.multi_get(state, 1, ["base_card:uuid1"])
      assert map_size(results) == 1
      assert results["base_card:uuid1"] == %{front: "Hello", back: "Hola"}
    end

    # RMX004_2A_T3: Test multi_get with multiple keys
    test "T3: multi_get/2 with multiple keys returns all found keys" do
      {:ok, state} = ETS.init([])

      # Put multiple values
      :ok = ETS.put(state, 1, "base_card:uuid1", %{front: "Hello"})
      :ok = ETS.put(state, 1, "base_card:uuid2", %{front: "Goodbye"})
      :ok = ETS.put(state, 1, "base_card:uuid3", %{front: "Thank you"})

      # Multi-get multiple keys
      keys = ["base_card:uuid1", "base_card:uuid2", "base_card:uuid3"]
      assert {:ok, results} = ETS.multi_get(state, 1, keys)

      assert map_size(results) == 3
      assert results["base_card:uuid1"] == %{front: "Hello"}
      assert results["base_card:uuid2"] == %{front: "Goodbye"}
      assert results["base_card:uuid3"] == %{front: "Thank you"}
    end

    # RMX004_2A_T4: Test multi_get with missing keys
    test "T4: multi_get/2 with missing keys omits missing keys from results" do
      {:ok, state} = ETS.init([])

      # Put only some values
      :ok = ETS.put(state, 1, "base_card:uuid1", %{front: "Hello"})
      :ok = ETS.put(state, 1, "base_card:uuid3", %{front: "Thank you"})

      # Multi-get including missing key
      keys = ["base_card:uuid1", "base_card:uuid2", "base_card:uuid3"]
      assert {:ok, results} = ETS.multi_get(state, 1, keys)

      # Should only return the keys that exist
      assert map_size(results) == 2
      assert results["base_card:uuid1"] == %{front: "Hello"}
      assert results["base_card:uuid3"] == %{front: "Thank you"}
      refute Map.has_key?(results, "base_card:uuid2")
    end

    # RMX004_2A_T5: Test multi_put with empty list
    test "T5: multi_put/2 with empty list returns :ok" do
      {:ok, state} = ETS.init([])

      assert :ok = ETS.multi_put(state, 1, [])
    end

    # RMX004_2A_T6: Test multi_put with single entry
    test "T6: multi_put/2 with single entry stores the entry" do
      {:ok, state} = ETS.init([])

      entries = [{"base_card:uuid1", %{front: "Hello", back: "Hola"}}]
      assert :ok = ETS.multi_put(state, 1, entries)

      # Verify the entry was stored
      assert {:ok, %{front: "Hello", back: "Hola"}} = ETS.get(state, 1, "base_card:uuid1")
    end

    # RMX004_2A_T7: Test multi_put with multiple entries
    test "T7: multi_put/2 with multiple entries stores all entries" do
      {:ok, state} = ETS.init([])

      entries = [
        {"base_card:uuid1", %{front: "Hello"}},
        {"base_card:uuid2", %{front: "Goodbye"}},
        {"base_card:uuid3", %{front: "Thank you"}}
      ]

      assert :ok = ETS.multi_put(state, 1, entries)

      # Verify all entries were stored
      assert {:ok, %{front: "Hello"}} = ETS.get(state, 1, "base_card:uuid1")
      assert {:ok, %{front: "Goodbye"}} = ETS.get(state, 1, "base_card:uuid2")
      assert {:ok, %{front: "Thank you"}} = ETS.get(state, 1, "base_card:uuid3")
    end

    # RMX004_2A_T8: Test multi_put overwrites existing
    test "T8: multi_put/2 overwrites existing entries" do
      {:ok, state} = ETS.init([])

      # Put initial values
      :ok = ETS.put(state, 1, "base_card:uuid1", %{front: "Old Hello"})
      :ok = ETS.put(state, 1, "base_card:uuid2", %{front: "Old Goodbye"})

      # Verify initial values
      assert {:ok, %{front: "Old Hello"}} = ETS.get(state, 1, "base_card:uuid1")
      assert {:ok, %{front: "Old Goodbye"}} = ETS.get(state, 1, "base_card:uuid2")

      # Overwrite with multi_put
      entries = [
        {"base_card:uuid1", %{front: "New Hello"}},
        {"base_card:uuid2", %{front: "New Goodbye"}}
      ]

      assert :ok = ETS.multi_put(state, 1, entries)

      # Verify values were overwritten
      assert {:ok, %{front: "New Hello"}} = ETS.get(state, 1, "base_card:uuid1")
      assert {:ok, %{front: "New Goodbye"}} = ETS.get(state, 1, "base_card:uuid2")
    end
  end

  describe "RMX004_2A: Multi-Operations Edge Cases" do
    test "multi_get/2 with all missing keys returns empty map" do
      {:ok, state} = ETS.init([])

      keys = ["base_card:uuid1", "base_card:uuid2", "base_card:uuid3"]
      assert {:ok, results} = ETS.multi_get(state, 1, keys)
      assert results == %{}
    end

    test "multi_put/2 with mixed new and existing entries works correctly" do
      {:ok, state} = ETS.init([])

      # Put initial value
      :ok = ETS.put(state, 1, "base_card:uuid1", %{front: "Existing"})

      # Multi-put with mix of existing and new
      entries = [
        {"base_card:uuid1", %{front: "Updated"}},
        {"base_card:uuid2", %{front: "New"}}
      ]

      assert :ok = ETS.multi_put(state, 1, entries)

      # Verify both are correct
      assert {:ok, %{front: "Updated"}} = ETS.get(state, 1, "base_card:uuid1")
      assert {:ok, %{front: "New"}} = ETS.get(state, 1, "base_card:uuid2")
    end

    test "multi_get/2 and multi_put/2 work together" do
      {:ok, state} = ETS.init([])

      # Multi-put some entries
      entries = [
        {"base_card:uuid1", %{front: "Hello"}},
        {"base_card:uuid2", %{front: "Goodbye"}},
        {"base_card:uuid3", %{front: "Thank you"}}
      ]

      :ok = ETS.multi_put(state, 1, entries)

      # Multi-get all entries
      keys = ["base_card:uuid1", "base_card:uuid2", "base_card:uuid3"]
      assert {:ok, results} = ETS.multi_get(state, 1, keys)

      assert map_size(results) == 3
      assert results["base_card:uuid1"] == %{front: "Hello"}
      assert results["base_card:uuid2"] == %{front: "Goodbye"}
      assert results["base_card:uuid3"] == %{front: "Thank you"}
    end

    test "multi_put/2 with duplicate keys uses last value" do
      {:ok, state} = ETS.init([])

      # Multi-put with duplicate keys
      entries = [
        {"base_card:uuid1", %{front: "First"}},
        {"base_card:uuid1", %{front: "Second"}},
        {"base_card:uuid1", %{front: "Third"}}
      ]

      assert :ok = ETS.multi_put(state, 1, entries)

      # ETS insert with list processes entries in order, so last one wins
      assert {:ok, %{front: "Third"}} = ETS.get(state, 1, "base_card:uuid1")
    end

    test "multi_get/2 with duplicate keys in input returns single entry" do
      {:ok, state} = ETS.init([])

      # Put a value
      :ok = ETS.put(state, 1, "base_card:uuid1", %{front: "Hello"})

      # Multi-get with duplicate keys
      keys = ["base_card:uuid1", "base_card:uuid1", "base_card:uuid1"]
      assert {:ok, results} = ETS.multi_get(state, 1, keys)

      # Should return single entry
      assert map_size(results) == 1
      assert results["base_card:uuid1"] == %{front: "Hello"}
    end

    test "multi_put/2 handles nil values" do
      {:ok, state} = ETS.init([])

      entries = [
        {"key1", nil},
        {"key2", %{value: "not nil"}}
      ]

      assert :ok = ETS.multi_put(state, 1, entries)

      assert {:ok, nil} = ETS.get(state, 1, "key1")
      assert {:ok, %{value: "not nil"}} = ETS.get(state, 1, "key2")
    end

    test "multi_get/2 with large batch (100 keys)" do
      {:ok, state} = ETS.init([])

      # Put 100 entries
      entries =
        Enum.map(1..100, fn i ->
          {"base_card:uuid#{i}", %{front: "Card #{i}"}}
        end)

      :ok = ETS.multi_put(state, 1, entries)

      # Multi-get all 100
      keys = Enum.map(1..100, fn i -> "base_card:uuid#{i}" end)
      assert {:ok, results} = ETS.multi_get(state, 1, keys)

      assert map_size(results) == 100

      # Spot check a few
      assert results["base_card:uuid1"] == %{front: "Card 1"}
      assert results["base_card:uuid50"] == %{front: "Card 50"}
      assert results["base_card:uuid100"] == %{front: "Card 100"}
    end

    test "multi_put/2 with large batch (100 entries)" do
      {:ok, state} = ETS.init([])

      # Multi-put 100 entries
      entries =
        Enum.map(1..100, fn i ->
          {"base_card:uuid#{i}", %{front: "Card #{i}", back: "Back #{i}"}}
        end)

      assert :ok = ETS.multi_put(state, 1, entries)

      # Verify all were stored
      Enum.each(1..100, fn i ->
        key = "base_card:uuid#{i}"
        expected_front = "Card #{i}"
        expected_back = "Back #{i}"
        assert {:ok, %{front: ^expected_front, back: ^expected_back}} = ETS.get(state, 1, key)
      end)
    end
  end
end
