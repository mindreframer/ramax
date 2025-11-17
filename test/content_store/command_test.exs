defmodule ContentStore.CommandTest do
  use ExUnit.Case, async: true

  alias ContentStore.Command
  alias PState
  alias PState.Ref

  @moduletag :content_store

  describe "RMX006_1A: Command Module - create_deck" do
    test "RMX006_1A_T1: create_deck generates deck.created event" do
      pstate = PState.new("content:root", adapter: PState.Adapters.ETS)

      params = %{deck_id: "spanish-101", name: "Spanish Basics"}

      assert {:ok, events} = Command.create_deck(pstate, params)
      assert length(events) == 1

      assert [{"deck.created", payload}] = events
      assert payload.deck_id == "spanish-101"
      assert payload.name == "Spanish Basics"
    end

    test "create_deck returns error when deck already exists" do
      pstate = PState.new("content:root", adapter: PState.Adapters.ETS)

      # Add existing deck to pstate
      deck_data = %{
        id: "spanish-101",
        name: "Existing Deck",
        cards: %{}
      }

      pstate = put_in(pstate["deck:spanish-101"], deck_data)

      params = %{deck_id: "spanish-101", name: "New Deck"}

      assert {:error, {:deck_already_exists, "spanish-101"}} = Command.create_deck(pstate, params)
    end
  end

  describe "RMX006_1A: Command Module - create_card" do
    setup do
      pstate = PState.new("content:root", adapter: PState.Adapters.ETS)

      # Create a deck in pstate
      deck_data = %{
        id: "deck-1",
        name: "Test Deck",
        cards: %{}
      }

      pstate = put_in(pstate["deck:deck-1"], deck_data)

      {:ok, pstate: pstate}
    end

    test "RMX006_1A_T2: create_card validates deck exists", %{pstate: _pstate} do
      pstate = PState.new("content:root", adapter: PState.Adapters.ETS)

      params = %{
        card_id: "card-1",
        deck_id: "nonexistent-deck",
        front: "Hello",
        back: "Hola"
      }

      assert {:error, {:deck_not_found, "nonexistent-deck"}} = Command.create_card(pstate, params)
    end

    test "RMX006_1A_T3: create_card validates card doesn't exist", %{pstate: pstate} do
      # Add existing card
      card_data = %{
        id: "card-1",
        front: "Hello",
        back: "Hola",
        deck: Ref.new(:deck, "deck-1")
      }

      pstate = put_in(pstate["card:card-1"], card_data)

      params = %{
        card_id: "card-1",
        deck_id: "deck-1",
        front: "New Front",
        back: "New Back"
      }

      assert {:error, {:card_already_exists, "card-1"}} = Command.create_card(pstate, params)
    end

    test "RMX006_1A_T4: create_card generates card.created event", %{pstate: pstate} do
      params = %{
        card_id: "card-1",
        deck_id: "deck-1",
        front: "Hello",
        back: "Hola"
      }

      assert {:ok, events} = Command.create_card(pstate, params)
      assert length(events) == 1

      assert [{"card.created", payload}] = events
      assert payload.card_id == "card-1"
      assert payload.deck_id == "deck-1"
      assert payload.front == "Hello"
      assert payload.back == "Hola"
    end

    test "RMX006_1A_T5: create_card returns error when deck not found" do
      pstate = PState.new("content:root", adapter: PState.Adapters.ETS)

      params = %{
        card_id: "card-1",
        deck_id: "missing-deck",
        front: "Hello",
        back: "Hola"
      }

      assert {:error, {:deck_not_found, "missing-deck"}} = Command.create_card(pstate, params)
    end

    test "RMX006_1A_T6: create_card returns error when card exists", %{pstate: pstate} do
      # Add existing card
      card_data = %{
        id: "existing-card",
        front: "Existing",
        back: "Card"
      }

      pstate = put_in(pstate["card:existing-card"], card_data)

      params = %{
        card_id: "existing-card",
        deck_id: "deck-1",
        front: "New",
        back: "Card"
      }

      assert {:error, {:card_already_exists, "existing-card"}} =
               Command.create_card(pstate, params)
    end
  end

  describe "RMX006_1A: Command Module - update_card" do
    setup do
      pstate = PState.new("content:root", adapter: PState.Adapters.ETS)

      # Create a card in pstate
      card_data = %{
        id: "card-1",
        front: "Hello",
        back: "Hola",
        deck: Ref.new(:deck, "deck-1"),
        translations: %{}
      }

      pstate = put_in(pstate["card:card-1"], card_data)

      {:ok, pstate: pstate}
    end

    test "RMX006_1A_T7: update_card validates card exists" do
      pstate = PState.new("content:root", adapter: PState.Adapters.ETS)

      params = %{
        card_id: "nonexistent-card",
        front: "New Front",
        back: "New Back"
      }

      assert {:error, {:card_not_found, "nonexistent-card"}} =
               Command.update_card(pstate, params)
    end

    test "RMX006_1A_T8: update_card validates content changed", %{pstate: pstate} do
      params = %{
        card_id: "card-1",
        front: "Hello",
        back: "Hola"
      }

      assert {:error, :no_changes} = Command.update_card(pstate, params)
    end

    test "RMX006_1A_T9: update_card generates card.updated event", %{pstate: pstate} do
      params = %{
        card_id: "card-1",
        front: "Hi",
        back: "Hola"
      }

      assert {:ok, events} = Command.update_card(pstate, params)
      assert length(events) >= 1

      # First event should be card.updated
      assert {"card.updated", payload} = hd(events)
      assert payload.card_id == "card-1"
      assert payload.front == "Hi"
      assert payload.back == "Hola"
    end

    test "RMX006_1A_T10: update_card generates invalidation when significant change", %{
      pstate: pstate
    } do
      params = %{
        card_id: "card-1",
        front: "Hello World!",
        back: "Hola Mundo!"
      }

      assert {:ok, events} = Command.update_card(pstate, params)
      assert length(events) == 2

      assert [{"card.updated", _}, {"card.translations.invalidated", invalidation_payload}] =
               events

      assert invalidation_payload.card_id == "card-1"
    end

    test "RMX006_1A_T11: update_card returns error for no changes", %{pstate: pstate} do
      params = %{
        card_id: "card-1",
        front: "Hello",
        back: "Hola"
      }

      assert {:error, :no_changes} = Command.update_card(pstate, params)
    end
  end

  describe "RMX006_1A: Command Module - add_translation" do
    setup do
      pstate = PState.new("content:root", adapter: PState.Adapters.ETS)

      # Create a card in pstate
      card_data = %{
        id: "card-1",
        front: "Hello",
        back: "Hola",
        deck: Ref.new(:deck, "deck-1"),
        translations: %{}
      }

      pstate = put_in(pstate["card:card-1"], card_data)

      {:ok, pstate: pstate}
    end

    test "RMX006_1A_T12: add_translation validates card exists" do
      pstate = PState.new("content:root", adapter: PState.Adapters.ETS)

      params = %{
        card_id: "nonexistent-card",
        field: :front,
        language: "fr",
        translation: "Bonjour"
      }

      assert {:error, {:card_not_found, "nonexistent-card"}} =
               Command.add_translation(pstate, params)
    end

    test "RMX006_1A_T13: add_translation validates translation is new", %{pstate: pstate} do
      # Add existing translation
      card_data = %{
        id: "card-1",
        front: "Hello",
        back: "Hola",
        translations: %{
          front: %{
            "fr" => %{text: "Bonjour", added_at: 1_234_567_890}
          }
        }
      }

      pstate = put_in(pstate["card:card-1"], card_data)

      params = %{
        card_id: "card-1",
        field: :front,
        language: "fr",
        translation: "Salut"
      }

      assert {:error, :translation_exists} = Command.add_translation(pstate, params)
    end

    test "RMX006_1A_T14: add_translation generates card.translation.added event", %{
      pstate: pstate
    } do
      params = %{
        card_id: "card-1",
        field: :front,
        language: "fr",
        translation: "Bonjour"
      }

      assert {:ok, events} = Command.add_translation(pstate, params)
      assert length(events) == 1

      assert [{"card.translation.added", payload}] = events
      assert payload.card_id == "card-1"
      assert payload.field == :front
      assert payload.language == "fr"
      assert payload.translation == "Bonjour"
    end

    test "RMX006_1A_T15: add_translation returns error when translation exists", %{
      pstate: pstate
    } do
      # Add existing translation
      card_data = %{
        id: "card-1",
        front: "Hello",
        back: "Hola",
        translations: %{
          back: %{
            "de" => %{text: "Tschüss", added_at: 1_234_567_890}
          }
        }
      }

      pstate = put_in(pstate["card:card-1"], card_data)

      params = %{
        card_id: "card-1",
        field: :back,
        language: "de",
        translation: "Auf Wiedersehen"
      }

      assert {:error, :translation_exists} = Command.add_translation(pstate, params)
    end
  end
end
