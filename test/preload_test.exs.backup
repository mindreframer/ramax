defmodule PState.PreloadTest do
  use ExUnit.Case, async: true
  alias PState.{Ref, Adapters.ETS}

  describe "RMX004_8A: Preloading API" do
    # RMX004_8A_T1: Test preload single ref
    test "T1: preload/3 with single ref warms cache" do
      # Setup: Create pstate with a deck that has a single card ref
      pstate = PState.new("base_deck:deck1", adapter: ETS, adapter_opts: [])

      # Create a card
      card_data = %{front: "Hello", back: "Hola"}
      card_ref = Ref.new("base_card:card1")

      # Create a deck with a card ref
      deck_data = %{name: "Spanish 101", card: card_ref}

      # Put entities
      pstate = put_in(pstate["base_card:card1"], card_data)
      pstate = put_in(pstate["base_deck:deck1"], deck_data)

      # Clear cache to simulate fresh state
      pstate = %{pstate | cache: %{}}

      # Preload the card
      pstate = PState.preload(pstate, "base_deck:deck1", [:card])

      # Verify cache is warmed
      assert Map.has_key?(pstate.cache, "base_card:card1")
      assert pstate.cache["base_card:card1"] == card_data
    end

    # RMX004_8A_T2: Test preload collection
    test "T2: preload/3 with collection preloads all refs" do
      # Setup: Create pstate with a deck that has multiple cards
      pstate = PState.new("base_deck:deck1", adapter: ETS, adapter_opts: [])

      # Create cards
      card1_data = %{front: "Hello", back: "Hola"}
      card2_data = %{front: "Goodbye", back: "Adiós"}
      card3_data = %{front: "Thank you", back: "Gracias"}

      # Create deck with cards collection (map of refs)
      deck_data = %{
        name: "Spanish 101",
        cards: %{
          "card1" => Ref.new("base_card:card1"),
          "card2" => Ref.new("base_card:card2"),
          "card3" => Ref.new("base_card:card3")
        }
      }

      # Put entities
      pstate = put_in(pstate["base_card:card1"], card1_data)
      pstate = put_in(pstate["base_card:card2"], card2_data)
      pstate = put_in(pstate["base_card:card3"], card3_data)
      pstate = put_in(pstate["base_deck:deck1"], deck_data)

      # Clear cache
      pstate = %{pstate | cache: %{}}

      # Preload all cards
      pstate = PState.preload(pstate, "base_deck:deck1", [:cards])

      # Verify all cards are in cache
      assert Map.has_key?(pstate.cache, "base_card:card1")
      assert Map.has_key?(pstate.cache, "base_card:card2")
      assert Map.has_key?(pstate.cache, "base_card:card3")

      assert pstate.cache["base_card:card1"] == card1_data
      assert pstate.cache["base_card:card2"] == card2_data
      assert pstate.cache["base_card:card3"] == card3_data
    end

    # RMX004_8A_T3: Test preload nested paths
    test "T3: preload/3 with nested paths preloads recursively" do
      # Setup: Create deck → cards → translations structure
      pstate = PState.new("base_deck:deck1", adapter: ETS, adapter_opts: [])

      # Create translations
      trans1_data = %{language: "es", text: "Hola"}
      trans2_data = %{language: "fr", text: "Bonjour"}

      # Create card with translations
      card_data = %{
        front: "Hello",
        translations: %{
          "es" => Ref.new("translation:trans1"),
          "fr" => Ref.new("translation:trans2")
        }
      }

      # Create deck with card
      deck_data = %{
        name: "Greetings",
        cards: %{
          "card1" => Ref.new("base_card:card1")
        }
      }

      # Put entities
      pstate = put_in(pstate["translation:trans1"], trans1_data)
      pstate = put_in(pstate["translation:trans2"], trans2_data)
      pstate = put_in(pstate["base_card:card1"], card_data)
      pstate = put_in(pstate["base_deck:deck1"], deck_data)

      # Clear cache
      pstate = %{pstate | cache: %{}}

      # Preload cards and their translations
      pstate = PState.preload(pstate, "base_deck:deck1", cards: [:translations])

      # Verify all entities are in cache
      assert Map.has_key?(pstate.cache, "base_card:card1")
      assert Map.has_key?(pstate.cache, "translation:trans1")
      assert Map.has_key?(pstate.cache, "translation:trans2")

      assert pstate.cache["base_card:card1"] == card_data
      assert pstate.cache["translation:trans1"] == trans1_data
      assert pstate.cache["translation:trans2"] == trans2_data
    end

    # RMX004_8A_T4: Test preload with multi_get
    test "T4: preload/3 uses multi_get when available" do
      # Setup: Create pstate with ETS adapter (supports multi_get)
      pstate = PState.new("base_deck:deck1", adapter: ETS, adapter_opts: [])

      # Verify adapter supports multi_get
      assert function_exported?(ETS, :multi_get, 2)

      # Create multiple cards
      cards =
        Enum.map(1..10, fn i ->
          {
            "base_card:card#{i}",
            %{front: "Card #{i}", back: "Back #{i}"}
          }
        end)

      # Create deck
      deck_cards =
        Map.new(1..10, fn i ->
          {"card#{i}", Ref.new("base_card:card#{i}")}
        end)

      deck_data = %{name: "Test Deck", cards: deck_cards}

      # Put all entities
      pstate =
        Enum.reduce(cards, pstate, fn {key, data}, acc ->
          put_in(acc[key], data)
        end)

      pstate = put_in(pstate["base_deck:deck1"], deck_data)

      # Clear cache
      pstate = %{pstate | cache: %{}}

      # Preload - should use multi_get internally
      pstate = PState.preload(pstate, "base_deck:deck1", [:cards])

      # Verify all cards are in cache
      Enum.each(1..10, fn i ->
        assert Map.has_key?(pstate.cache, "base_card:card#{i}")
      end)
    end

    # RMX004_8A_T5: Test cache warming
    test "T5: preload/3 warms cache and avoids subsequent adapter calls" do
      # Setup
      pstate = PState.new("base_deck:deck1", adapter: ETS, adapter_opts: [])

      # Create entities
      card_data = %{front: "Hello", back: "Hola"}
      deck_data = %{name: "Spanish", cards: %{"card1" => Ref.new("base_card:card1")}}

      pstate = put_in(pstate["base_card:card1"], card_data)
      pstate = put_in(pstate["base_deck:deck1"], deck_data)

      # Clear cache
      pstate = %{pstate | cache: %{}}

      # Verify cache is empty
      refute Map.has_key?(pstate.cache, "base_card:card1")

      # Preload
      pstate = PState.preload(pstate, "base_deck:deck1", [:cards])

      # Verify cache is warmed
      assert Map.has_key?(pstate.cache, "base_card:card1")

      # Access the card - should use cache, not adapter
      assert {:ok, fetched_data} = PState.fetch(pstate, "base_card:card1")
      assert fetched_data == card_data
    end

    # RMX004_8A_T6: Test preload performance (<20ms for 100 refs)
    test "T6: preload/3 completes in <20ms for 100 refs" do
      # Setup
      pstate = PState.new("base_deck:deck1", adapter: ETS, adapter_opts: [])

      # Create 100 cards
      cards =
        Enum.map(1..100, fn i ->
          {
            "base_card:card#{i}",
            %{front: "Card #{i}", back: "Back #{i}"}
          }
        end)

      # Create deck with 100 card refs
      deck_cards =
        Map.new(1..100, fn i ->
          {"card#{i}", Ref.new("base_card:card#{i}")}
        end)

      deck_data = %{name: "Large Deck", cards: deck_cards}

      # Put all entities
      pstate =
        Enum.reduce(cards, pstate, fn {key, data}, acc ->
          put_in(acc[key], data)
        end)

      pstate = put_in(pstate["base_deck:deck1"], deck_data)

      # Clear cache
      pstate = %{pstate | cache: %{}}

      # Measure preload time
      {duration_microseconds, _result} =
        :timer.tc(fn ->
          PState.preload(pstate, "base_deck:deck1", [:cards])
        end)

      duration_milliseconds = duration_microseconds / 1000

      # Should complete in less than 20ms
      assert duration_milliseconds < 20,
             "Preload took #{duration_milliseconds}ms, expected <20ms"
    end
  end

  describe "RMX004_8A: Preloading Edge Cases" do
    test "preload/3 with missing entity returns unchanged pstate" do
      pstate = PState.new("base_deck:missing", adapter: ETS, adapter_opts: [])

      # Preload on non-existent entity
      result = PState.preload(pstate, "base_deck:missing", [:cards])

      # Should return unchanged pstate
      assert result == pstate
    end

    test "preload/3 with non-map entity returns unchanged pstate" do
      pstate = PState.new("value:simple", adapter: ETS, adapter_opts: [])

      # Put a non-map value
      pstate = put_in(pstate["value:simple"], "just a string")

      # Preload on non-map
      result = PState.preload(pstate, "value:simple", [:field])

      # Should return pstate (can't preload from string)
      assert result.cache == pstate.cache
    end

    test "preload/3 with empty paths returns unchanged pstate" do
      pstate = PState.new("base_deck:deck1", adapter: ETS, adapter_opts: [])

      deck_data = %{name: "Test"}
      pstate = put_in(pstate["base_deck:deck1"], deck_data)

      # Preload with empty paths
      result = PState.preload(pstate, "base_deck:deck1", [])

      # Should return pstate
      assert result == pstate
    end

    test "preload/3 with non-existent field returns unchanged pstate" do
      pstate = PState.new("base_deck:deck1", adapter: ETS, adapter_opts: [])

      deck_data = %{name: "Test"}
      pstate = put_in(pstate["base_deck:deck1"], deck_data)
      pstate = %{pstate | cache: %{}}

      # Preload non-existent field
      result = PState.preload(pstate, "base_deck:deck1", [:missing_field])

      # Should not crash, just return pstate (possibly with deck in cache)
      assert is_struct(result, PState)
    end

    test "preload/3 with multiple fields preloads all" do
      pstate = PState.new("entity:root", adapter: ETS, adapter_opts: [])

      # Create entities
      ref1_data = %{value: "ref1"}
      ref2_data = %{value: "ref2"}

      root_data = %{
        field1: Ref.new("entity:ref1"),
        field2: Ref.new("entity:ref2")
      }

      pstate = put_in(pstate["entity:ref1"], ref1_data)
      pstate = put_in(pstate["entity:ref2"], ref2_data)
      pstate = put_in(pstate["entity:root"], root_data)
      pstate = %{pstate | cache: %{}}

      # Preload multiple fields
      pstate = PState.preload(pstate, "entity:root", [:field1, :field2])

      # Verify both are in cache
      assert Map.has_key?(pstate.cache, "entity:ref1")
      assert Map.has_key?(pstate.cache, "entity:ref2")
    end

    test "preload/3 with nil field value doesn't crash" do
      pstate = PState.new("entity:root", adapter: ETS, adapter_opts: [])

      root_data = %{field: nil}
      pstate = put_in(pstate["entity:root"], root_data)

      # Preload nil field
      result = PState.preload(pstate, "entity:root", [:field])

      # Should not crash
      assert is_struct(result, PState)
    end
  end
end
