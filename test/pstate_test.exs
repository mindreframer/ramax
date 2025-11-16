defmodule PStateTest do
  use ExUnit.Case, async: true

  alias PState

  describe "PState struct" do
    test "RMX001_1A_T4: has all required fields" do
      # Create a PState struct with all fields
      pstate = %PState{
        root_key: "track:uuid",
        adapter: PState.Adapters.ETS,
        adapter_state: %{table: :test_table},
        cache: %{},
        ref_cache: %{}
      }

      assert pstate.root_key == "track:uuid"
      assert pstate.adapter == PState.Adapters.ETS
      assert pstate.adapter_state == %{table: :test_table}
      assert pstate.cache == %{}
      assert pstate.ref_cache == %{}
    end

    test "RMX001_1A_T5: enforces required keys" do
      # Should raise when root_key is missing
      assert_raise ArgumentError, fn ->
        struct!(PState, %{
          adapter: PState.Adapters.ETS,
          adapter_state: %{table: :test_table}
        })
      end

      # Should raise when adapter is missing
      assert_raise ArgumentError, fn ->
        struct!(PState, %{
          root_key: "track:uuid",
          adapter_state: %{table: :test_table}
        })
      end

      # Should raise when adapter_state is missing
      assert_raise ArgumentError, fn ->
        struct!(PState, %{
          root_key: "track:uuid",
          adapter: PState.Adapters.ETS
        })
      end
    end

    test "cache defaults to empty map" do
      pstate = %PState{
        root_key: "track:uuid",
        adapter: PState.Adapters.ETS,
        adapter_state: %{table: :test_table}
      }

      assert pstate.cache == %{}
      assert pstate.ref_cache == %{}
    end

    test "allows custom cache values" do
      pstate = %PState{
        root_key: "track:uuid",
        adapter: PState.Adapters.ETS,
        adapter_state: %{table: :test_table},
        cache: %{"key1" => "value1"},
        ref_cache: %{"ref1" => "resolved1"}
      }

      assert pstate.cache == %{"key1" => "value1"}
      assert pstate.ref_cache == %{"ref1" => "resolved1"}
    end
  end

  describe "PState.new/2 (RMX001_3A)" do
    test "RMX001_3A_T1: creates PState with ETS adapter" do
      pstate =
        PState.new("track:550e8400-e29b-41d4-a716-446655440000",
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: :test_pstate_init_1]
        )

      assert %PState{} = pstate
      assert pstate.root_key == "track:550e8400-e29b-41d4-a716-446655440000"
      assert pstate.adapter == PState.Adapters.ETS
      assert is_map(pstate.adapter_state)
      assert Map.has_key?(pstate.adapter_state, :table)
    end

    test "RMX001_3A_T2: initializes empty caches" do
      pstate =
        PState.new("track:uuid",
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: :test_pstate_init_2]
        )

      assert pstate.cache == %{}
      assert pstate.ref_cache == %{}
    end

    test "RMX001_3A_T3: fails with invalid adapter" do
      # Missing adapter option
      assert_raise KeyError, fn ->
        PState.new("track:uuid", adapter_opts: [table_name: :test])
      end
    end
  end

  describe "PState.create_linked/2 (RMX001_5A)" do
    setup do
      pstate =
        PState.new("track:uuid",
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: :test_bidirectional_refs]
        )

      # Create a parent entity first
      parent_id = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
      parent_key = "base_deck:#{parent_id}"

      pstate =
        put_in(pstate[parent_key], %{
          id: parent_id,
          title: "Introduction",
          cards: %{}
        })

      {:ok, pstate: pstate, parent_id: parent_id}
    end

    test "RMX001_5A_T1: creates child entity", %{pstate: pstate, parent_id: parent_id} do
      card_id = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

      pstate =
        PState.create_linked(pstate,
          entity: {:base_card, card_id},
          data: %{front: "Hello", back: "Hola"},
          parent: {:base_deck, parent_id},
          parent_collection: :cards
        )

      # Verify child entity was created
      {:ok, card} = PState.fetch(pstate, "base_card:#{card_id}")
      assert card.front == "Hello"
      assert card.back == "Hola"
    end

    test "RMX001_5A_T2: adds parent ref to child", %{pstate: pstate, parent_id: parent_id} do
      card_id = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

      pstate =
        PState.create_linked(pstate,
          entity: {:base_card, card_id},
          data: %{front: "Hello", back: "Hola"},
          parent: {:base_deck, parent_id},
          parent_collection: :cards
        )

      # Verify child has parent ref (which auto-resolves when fetched)
      {:ok, card} = PState.fetch(pstate, "base_card:#{card_id}")
      # The base_deck ref should resolve to the actual deck
      assert is_map(card.base_deck)
      assert card.base_deck.id == parent_id
      assert card.base_deck.title == "Introduction"
    end

    test "RMX001_5A_T3: adds child ref to parent collection", %{
      pstate: pstate,
      parent_id: parent_id
    } do
      card_id = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

      pstate =
        PState.create_linked(pstate,
          entity: {:base_card, card_id},
          data: %{front: "Hello", back: "Hola"},
          parent: {:base_deck, parent_id},
          parent_collection: :cards
        )

      # Verify parent collection has child ref (which auto-resolves when fetched)
      {:ok, deck} = PState.fetch(pstate, "base_deck:#{parent_id}")
      assert is_map(deck.cards)
      # The child ref should resolve to the actual card
      card = deck.cards[card_id]
      assert is_map(card)
      assert card.front == "Hello"
      assert card.back == "Hola"
    end

    test "RMX001_5A_T4: works with custom collection name", %{
      pstate: pstate,
      parent_id: parent_id
    } do
      card_id = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

      pstate =
        PState.create_linked(pstate,
          entity: {:base_card, card_id},
          data: %{front: "Hello", back: "Hola"},
          parent: {:base_deck, parent_id},
          parent_collection: :items
        )

      # Verify child ref is in custom collection (as string key due to Helpers.Value)
      {:ok, deck} = PState.fetch(pstate, "base_deck:#{parent_id}")
      # Helpers.Value.insert converts atom keys to strings
      assert is_map(deck["items"])
      card = deck["items"][card_id]
      assert is_map(card)
      assert card.front == "Hello"
      assert card.back == "Hola"
    end

    test "RMX001_5A_T5: preserves existing parent collection", %{
      pstate: pstate,
      parent_id: parent_id
    } do
      # Create first card
      card1_id = "11111111-1111-1111-1111-111111111111"

      pstate =
        PState.create_linked(pstate,
          entity: {:base_card, card1_id},
          data: %{front: "First", back: "Primero"},
          parent: {:base_deck, parent_id},
          parent_collection: :cards
        )

      # Create second card
      card2_id = "22222222-2222-2222-2222-222222222222"

      pstate =
        PState.create_linked(pstate,
          entity: {:base_card, card2_id},
          data: %{front: "Second", back: "Segundo"},
          parent: {:base_deck, parent_id},
          parent_collection: :cards
        )

      # Verify both cards are in collection (refs auto-resolve)
      {:ok, deck} = PState.fetch(pstate, "base_deck:#{parent_id}")
      assert map_size(deck.cards) == 2

      # Check first card
      card1 = deck.cards[card1_id]
      assert is_map(card1)
      assert card1.front == "First"
      assert card1.back == "Primero"

      # Check second card
      card2 = deck.cards[card2_id]
      assert is_map(card2)
      assert card2.front == "Second"
      assert card2.back == "Segundo"
    end

    test "RMX001_5A_T6: allows bidirectional navigation (child→parent→child)", %{
      pstate: pstate,
      parent_id: parent_id
    } do
      card_id = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

      pstate =
        PState.create_linked(pstate,
          entity: {:base_card, card_id},
          data: %{front: "Hello", back: "Hola"},
          parent: {:base_deck, parent_id},
          parent_collection: :cards
        )

      # Navigate from child to parent (ref auto-resolves)
      {:ok, card} = PState.fetch(pstate, "base_card:#{card_id}")
      assert card.base_deck.id == parent_id
      assert card.base_deck.title == "Introduction"

      # Navigate from parent to child (ref auto-resolves)
      {:ok, deck} = PState.fetch(pstate, "base_deck:#{parent_id}")
      resolved_card = deck.cards[card_id]
      assert resolved_card.front == "Hello"
      assert resolved_card.back == "Hola"
    end
  end
end
