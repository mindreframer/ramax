defmodule FlashcardAppTest do
  use ExUnit.Case, async: true

  doctest FlashcardApp

  setup do
    # Create a fresh app for each test with unique table names
    # Use test process PID to ensure unique table names
    unique_id = :erlang.unique_integer([:positive])

    app =
      FlashcardApp.new(
        event_opts: [table_name: :"event_store_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_#{unique_id}"]
      )

    {:ok, app: app}
  end

  # RMX006_4A_T1: Test new/1 creates app
  test "new/1 creates app with ContentStore" do
    unique_id = :erlang.unique_integer([:positive])

    app =
      FlashcardApp.new(
        event_opts: [table_name: :"event_store_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_#{unique_id}"]
      )

    assert %FlashcardApp{} = app
    assert %ContentStore{} = app.store
    assert %EventStore{} = app.store.event_store
    assert %PState{} = app.store.pstate
  end

  # RMX006_4A_T2: Test create_deck creates deck in PState
  test "create_deck creates deck in PState", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")

    {:ok, deck} = FlashcardApp.get_deck(app, "spanish-101")

    assert deck.id == "spanish-101"
    assert deck.name == "Spanish Basics"
    assert deck.cards == %{}
    assert is_integer(deck.created_at)
  end

  # RMX006_4A_T3: Test create_deck appends event to event store
  test "create_deck appends event to event store", %{app: app} do
    event_count_before = FlashcardApp.get_event_count(app)

    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")

    event_count_after = FlashcardApp.get_event_count(app)

    assert event_count_after == event_count_before + 1
  end

  # RMX006_4A_T4: Test create_card creates card in PState
  test "create_card creates card in PState", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")

    {:ok, card} = FlashcardApp.get_card(app, "card-1")

    assert card.id == "card-1"
    assert card.front == "Hello"
    assert card.back == "Hola"
    assert card.translations == %{}
    assert is_integer(card.created_at)
  end

  # RMX006_4A_T5: Test create_card adds card to deck
  test "create_card adds card to deck", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")

    # Get deck with resolved refs to access full card data
    {:ok, deck} = PState.get_resolved(app.store.pstate, "deck:spanish-101", depth: :infinity)

    assert Map.has_key?(deck.cards, "card-1")
    # With get_resolved, refs are resolved and we get the full card
    assert deck.cards["card-1"].id == "card-1"
  end

  # RMX006_4A_T6: Test create_card fails when deck doesn't exist
  test "create_card fails when deck doesn't exist", %{app: app} do
    result = FlashcardApp.create_card(app, "card-1", "nonexistent", "Hello", "Hola")

    assert {:error, {:deck_not_found, "nonexistent"}} = result
  end

  # RMX006_4A_T7: Test create_card fails when card already exists
  test "create_card fails when card already exists", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")

    result = FlashcardApp.create_card(app, "card-1", "spanish-101", "Goodbye", "Adiós")

    assert {:error, {:card_already_exists, "card-1"}} = result
  end

  # RMX006_4A_T8: Test update_card updates card content
  test "update_card updates card content", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")

    {:ok, app} = FlashcardApp.update_card(app, "card-1", "Hello!", "¡Hola!")

    {:ok, card} = FlashcardApp.get_card(app, "card-1")

    assert card.front == "Hello!"
    assert card.back == "¡Hola!"
  end

  # RMX006_4A_T9: Test update_card sets updated_at
  test "update_card sets updated_at", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")

    {:ok, card_before} = FlashcardApp.get_card(app, "card-1")

    # Small delay to ensure timestamp changes
    Process.sleep(10)

    {:ok, app} = FlashcardApp.update_card(app, "card-1", "Hello!", "¡Hola!")

    {:ok, card_after} = FlashcardApp.get_card(app, "card-1")

    assert Map.has_key?(card_after, :updated_at)
    assert card_after.updated_at >= card_before.created_at
  end

  # RMX006_4A_T10: Test update_card fails when no changes
  test "update_card fails when no changes", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")

    result = FlashcardApp.update_card(app, "card-1", "Hello", "Hola")

    assert {:error, :no_changes} = result
  end

  # RMX006_4A_T11: Test add_translation adds translation to card
  test "add_translation adds translation to card", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")

    {:ok, app} = FlashcardApp.add_translation(app, "card-1", :front, "fr", "Bonjour")

    {:ok, card} = FlashcardApp.get_card(app, "card-1")

    assert card.translations[:front]["fr"].text == "Bonjour"
    assert is_integer(card.translations[:front]["fr"].added_at)
  end

  # RMX006_4A_T12: Test add_translation fails when translation exists
  test "add_translation fails when translation exists", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")
    {:ok, app} = FlashcardApp.add_translation(app, "card-1", :front, "fr", "Bonjour")

    result = FlashcardApp.add_translation(app, "card-1", :front, "fr", "Salut")

    assert {:error, :translation_exists} = result
  end

  # RMX006_4A_T13: Test get_deck returns deck data
  test "get_deck returns deck data", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")

    {:ok, deck} = FlashcardApp.get_deck(app, "spanish-101")

    assert deck.id == "spanish-101"
    assert deck.name == "Spanish Basics"
  end

  # RMX006_4A_T14: Test get_card returns card data
  test "get_card returns card data", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")

    {:ok, card} = FlashcardApp.get_card(app, "card-1")

    assert card.id == "card-1"
    assert card.front == "Hello"
    assert card.back == "Hola"
  end

  # RMX006_4A_T15: Test list_deck_cards returns all cards
  test "list_deck_cards returns all cards", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")
    {:ok, app} = FlashcardApp.create_card(app, "card-2", "spanish-101", "Goodbye", "Adiós")
    {:ok, app} = FlashcardApp.create_card(app, "card-3", "spanish-101", "Thank you", "Gracias")

    {:ok, cards} = FlashcardApp.list_deck_cards(app, "spanish-101")

    assert length(cards) == 3

    card_ids = Enum.map(cards, & &1.id)
    assert "card-1" in card_ids
    assert "card-2" in card_ids
    assert "card-3" in card_ids
  end

  # RMX006_4A_T16: Test get_event_count returns sequence
  test "get_event_count returns sequence", %{app: app} do
    assert FlashcardApp.get_event_count(app) == 0

    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    assert FlashcardApp.get_event_count(app) == 1

    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")
    assert FlashcardApp.get_event_count(app) == 2

    {:ok, app} = FlashcardApp.add_translation(app, "card-1", :front, "fr", "Bonjour")
    assert FlashcardApp.get_event_count(app) == 3
  end

  # RMX006_4A_T17: Test rebuild restores PState correctly
  test "rebuild restores PState correctly", %{app: app} do
    # Build up some state
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")
    {:ok, app} = FlashcardApp.create_card(app, "card-2", "spanish-101", "Goodbye", "Adiós")
    {:ok, app} = FlashcardApp.add_translation(app, "card-1", :front, "fr", "Bonjour")

    # Capture state before rebuild
    {:ok, deck_before} = FlashcardApp.get_deck(app, "spanish-101")
    {:ok, card1_before} = FlashcardApp.get_card(app, "card-1")
    {:ok, card2_before} = FlashcardApp.get_card(app, "card-2")

    # Rebuild
    app = FlashcardApp.rebuild(app)

    # Verify state after rebuild
    {:ok, deck_after} = FlashcardApp.get_deck(app, "spanish-101")
    {:ok, card1_after} = FlashcardApp.get_card(app, "card-1")
    {:ok, card2_after} = FlashcardApp.get_card(app, "card-2")

    assert deck_before == deck_after
    assert card1_before == card1_after
    assert card2_before == card2_after
  end

  # RMX006_4A_T18: Test complete scenario: create deck → add cards → translate → query
  test "complete scenario: create deck → add cards → translate → query", %{app: app} do
    # Create a Spanish learning deck
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")

    # Add some basic cards
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")
    {:ok, app} = FlashcardApp.create_card(app, "card-2", "spanish-101", "Goodbye", "Adiós")

    {:ok, app} =
      FlashcardApp.create_card(app, "card-3", "spanish-101", "Thank you", "Gracias")

    # Add French translations to first card
    {:ok, app} = FlashcardApp.add_translation(app, "card-1", :front, "fr", "Bonjour")
    {:ok, app} = FlashcardApp.add_translation(app, "card-1", :back, "fr", "Salut")

    # Add English translations to second card
    {:ok, app} = FlashcardApp.add_translation(app, "card-2", :back, "en", "Goodbye")

    # Update a card
    {:ok, app} = FlashcardApp.update_card(app, "card-3", "Thank you very much", "Muchas gracias")

    # Query the deck
    {:ok, deck} = FlashcardApp.get_deck(app, "spanish-101")
    assert deck.name == "Spanish Basics"
    assert map_size(deck.cards) == 3

    # Query cards
    {:ok, cards} = FlashcardApp.list_deck_cards(app, "spanish-101")
    assert length(cards) == 3

    # Verify card 1 has translations
    {:ok, card1} = FlashcardApp.get_card(app, "card-1")
    assert card1.translations[:front]["fr"].text == "Bonjour"
    assert card1.translations[:back]["fr"].text == "Salut"

    # Verify card 3 was updated
    {:ok, card3} = FlashcardApp.get_card(app, "card-3")
    assert card3.front == "Thank you very much"
    assert card3.back == "Muchas gracias"
    assert Map.has_key?(card3, :updated_at)

    # Verify event count
    event_count = FlashcardApp.get_event_count(app)

    # 1 deck.created + 3 card.created + 3 translation.added + 1 card.updated + 1 invalidation = 9 events
    # The update triggers invalidation because the length changed significantly
    assert event_count == 9

    # Rebuild and verify data integrity
    app = FlashcardApp.rebuild(app)

    {:ok, deck_after} = FlashcardApp.get_deck(app, "spanish-101")
    {:ok, card1_after} = FlashcardApp.get_card(app, "card-1")
    {:ok, card3_after} = FlashcardApp.get_card(app, "card-3")

    assert deck == deck_after
    assert card1 == card1_after
    assert card3 == card3_after
  end

  # Additional edge case tests
  test "get_deck returns error for nonexistent deck", %{app: app} do
    result = FlashcardApp.get_deck(app, "nonexistent")
    assert result == :error
  end

  test "get_card returns error for nonexistent card", %{app: app} do
    result = FlashcardApp.get_card(app, "nonexistent")
    assert result == :error
  end

  test "list_deck_cards returns error for nonexistent deck", %{app: app} do
    result = FlashcardApp.list_deck_cards(app, "nonexistent")
    assert {:error, :deck_not_found} = result
  end

  test "create_deck fails when deck already exists", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")

    result = FlashcardApp.create_deck(app, "spanish-101", "Spanish Advanced")

    assert {:error, {:deck_already_exists, "spanish-101"}} = result
  end

  test "update_card fails when card doesn't exist", %{app: app} do
    result = FlashcardApp.update_card(app, "nonexistent", "Hello", "Hola")

    assert {:error, {:card_not_found, "nonexistent"}} = result
  end

  test "add_translation fails when card doesn't exist", %{app: app} do
    result = FlashcardApp.add_translation(app, "nonexistent", :front, "fr", "Bonjour")

    assert {:error, {:card_not_found, "nonexistent"}} = result
  end

  test "multiple translations can be added to different fields", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101", "Hello", "Hola")

    {:ok, app} = FlashcardApp.add_translation(app, "card-1", :front, "fr", "Bonjour")
    {:ok, app} = FlashcardApp.add_translation(app, "card-1", :front, "de", "Guten Tag")
    {:ok, app} = FlashcardApp.add_translation(app, "card-1", :back, "en", "Hello")

    {:ok, card} = FlashcardApp.get_card(app, "card-1")

    assert card.translations[:front]["fr"].text == "Bonjour"
    assert card.translations[:front]["de"].text == "Guten Tag"
    assert card.translations[:back]["en"].text == "Hello"
  end

  test "list_deck_cards returns empty list for deck with no cards", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "empty-deck", "Empty Deck")

    {:ok, cards} = FlashcardApp.list_deck_cards(app, "empty-deck")

    assert cards == []
  end

  test "rebuild works with empty event store" do
    unique_id = :erlang.unique_integer([:positive])

    app =
      FlashcardApp.new(
        event_opts: [table_name: :"event_store_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_#{unique_id}"]
      )

    # Rebuild should work even with no events
    app = FlashcardApp.rebuild(app)

    assert %FlashcardApp{} = app
    assert FlashcardApp.get_event_count(app) == 0
  end

  test "can create multiple decks independently", %{app: app} do
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    {:ok, app} = FlashcardApp.create_deck(app, "french-101", "French Basics")
    {:ok, app} = FlashcardApp.create_deck(app, "german-101", "German Basics")

    {:ok, spanish_deck} = FlashcardApp.get_deck(app, "spanish-101")
    {:ok, french_deck} = FlashcardApp.get_deck(app, "french-101")
    {:ok, german_deck} = FlashcardApp.get_deck(app, "german-101")

    assert spanish_deck.name == "Spanish Basics"
    assert french_deck.name == "French Basics"
    assert german_deck.name == "German Basics"
  end
end
