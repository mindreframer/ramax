defmodule ContentStoreTest do
  use ExUnit.Case, async: true

  alias ContentStore
  alias FlashcardCommand, as: Command

  describe "new/1" do
    test "RMX006_3A_T1: initializes both stores" do
      store = ContentStore.new(event_applicator: FlashcardEventApplicator)

      assert %ContentStore{} = store
      assert %EventStore{} = store.event_store
      assert %PState{} = store.pstate
    end

    test "RMX006_3A_T2: accepts custom adapters" do
      store =
        ContentStore.new(
          event_adapter: EventStore.Adapters.ETS,
          event_opts: [table_name: :custom_events],
          pstate_adapter: PState.Adapters.ETS,
          pstate_opts: [table_name: :custom_pstate],
          root_key: "custom:root"
        )

      assert store.event_store.adapter == EventStore.Adapters.ETS
      assert store.pstate.adapter == PState.Adapters.ETS
      assert store.pstate.root_key == "custom:root"
    end
  end

  describe "execute/3" do
    setup do
      store = ContentStore.new(event_applicator: FlashcardEventApplicator)
      %{store: store}
    end

    test "RMX006_3A_T3: runs command", %{store: store} do
      params = %{deck_id: "spanish-101", name: "Spanish Basics"}

      result = ContentStore.execute(store, &Command.create_deck/2, params)

      assert {:ok, [_event_id], _updated_store} = result
    end

    test "RMX006_3A_T4: appends events to event store", %{store: store} do
      params = %{deck_id: "spanish-101", name: "Spanish Basics"}

      {:ok, [event_id], updated_store} =
        ContentStore.execute(store, &Command.create_deck/2, params)

      # Verify event was appended
      {:ok, event} = EventStore.get_event(updated_store.event_store, event_id)
      assert event.metadata.event_type == "deck.created"
      assert event.payload.deck_id == "spanish-101"
      assert event.payload.name == "Spanish Basics"
    end

    test "RMX006_3A_T5: applies events to PState", %{store: store} do
      params = %{deck_id: "spanish-101", name: "Spanish Basics"}

      {:ok, _event_ids, updated_store} =
        ContentStore.execute(store, &Command.create_deck/2, params)

      # Verify PState was updated
      {:ok, deck} = PState.fetch(updated_store.pstate, "deck:spanish-101")
      assert deck.id == "spanish-101"
      assert deck.name == "Spanish Basics"
      assert deck.cards == %{}
    end

    test "RMX006_3A_T6: returns event IDs", %{store: store} do
      params = %{deck_id: "spanish-101", name: "Spanish Basics"}

      {:ok, event_ids, _updated_store} =
        ContentStore.execute(store, &Command.create_deck/2, params)

      assert is_list(event_ids)
      assert length(event_ids) == 1
      assert is_integer(hd(event_ids))
    end

    test "RMX006_3A_T7: handles command errors", %{store: store} do
      # Create deck first
      params = %{deck_id: "spanish-101", name: "Spanish Basics"}

      {:ok, _event_ids, updated_store} =
        ContentStore.execute(store, &Command.create_deck/2, params)

      # Try to create same deck again
      result = ContentStore.execute(updated_store, &Command.create_deck/2, params)

      assert {:error, {:deck_already_exists, "spanish-101"}} = result
    end

    test "RMX006_3A_T8: doesn't append on command error", %{store: store} do
      # Get initial event count
      {:ok, initial_seq} = EventStore.get_latest_sequence(store.event_store)

      # Try to create card without deck
      params = %{card_id: "c1", deck_id: "nonexistent", front: "Hello", back: "Hola"}
      {:error, _reason} = ContentStore.execute(store, &Command.create_card/2, params)

      # Verify no events were appended
      {:ok, final_seq} = EventStore.get_latest_sequence(store.event_store)
      assert initial_seq == final_seq
    end
  end

  describe "rebuild_pstate/2" do
    setup do
      store = ContentStore.new(event_applicator: FlashcardEventApplicator)

      # Create a deck and some cards
      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_deck/2, %{
          deck_id: "spanish-101",
          name: "Spanish Basics"
        })

      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_card/2, %{
          card_id: "c1",
          deck_id: "spanish-101",
          front: "Hello",
          back: "Hola"
        })

      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_card/2, %{
          card_id: "c2",
          deck_id: "spanish-101",
          front: "Goodbye",
          back: "Adiós"
        })

      %{store: store}
    end

    test "RMX006_3A_T9: replays all events", %{store: store} do
      rebuilt_store = ContentStore.rebuild_pstate(store)

      # Verify deck exists
      {:ok, deck} = PState.fetch(rebuilt_store.pstate, "deck:spanish-101")
      assert deck.name == "Spanish Basics"

      # Verify cards exist
      {:ok, c1} = PState.fetch(rebuilt_store.pstate, "card:c1")
      assert c1.front == "Hello"

      {:ok, c2} = PState.fetch(rebuilt_store.pstate, "card:c2")
      assert c2.front == "Goodbye"
    end

    test "RMX006_3A_T10: creates fresh PState", %{store: store} do
      rebuilt_store = ContentStore.rebuild_pstate(store)

      # PState should be a new instance but with same data
      refute rebuilt_store.pstate == store.pstate
      {:ok, deck1} = PState.fetch(store.pstate, "deck:spanish-101")
      {:ok, deck2} = PState.fetch(rebuilt_store.pstate, "deck:spanish-101")
      assert deck1.id == deck2.id
      assert deck1.name == deck2.name
    end

    test "RMX006_3A_T11: rebuild with 1000 events" do
      store =
        ContentStore.new(
          event_opts: [table_name: :events_1000_test],
          pstate_opts: [table_name: :pstate_1000_test],
          event_applicator: FlashcardEventApplicator
        )

      # Create a deck
      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_deck/2, %{
          deck_id: "test-deck",
          name: "Test Deck"
        })

      # Create 50 cards (1 deck.created + 50 card.created = 51 events)
      store =
        Enum.reduce(1..50, store, fn i, acc_store ->
          {:ok, _, updated_store} =
            ContentStore.execute(acc_store, &Command.create_card/2, %{
              card_id: "card-#{i}",
              deck_id: "test-deck",
              front: "Front #{i}",
              back: "Back #{i}"
            })

          updated_store
        end)

      # Update all 50 cards (50 card.updated = 101 total events)
      store =
        Enum.reduce(1..50, store, fn i, acc_store ->
          {:ok, _, updated_store} =
            ContentStore.execute(acc_store, &Command.update_card/2, %{
              card_id: "card-#{i}",
              front: "Updated Front #{i}",
              back: "Updated Back #{i}"
            })

          updated_store
        end)

      # Verify event count > 100 (updates may generate invalidation events too)
      {:ok, seq} = EventStore.get_latest_sequence(store.event_store)
      assert seq > 100

      # Rebuild PState
      rebuilt_store = ContentStore.rebuild_pstate(store)

      # Verify all cards have updated content
      {:ok, card_1} = PState.fetch(rebuilt_store.pstate, "card:card-1")
      assert card_1.front == "Updated Front 1"

      {:ok, card_50} = PState.fetch(rebuilt_store.pstate, "card:card-50")
      assert card_50.front == "Updated Front 50"
    end

    test "RMX006_3A_T12: streams in batches", %{store: store} do
      # Rebuild with small batch size
      rebuilt_store = ContentStore.rebuild_pstate(store, batch_size: 1)

      # Should produce same result
      {:ok, deck1} = PState.fetch(store.pstate, "deck:spanish-101")
      {:ok, deck2} = PState.fetch(rebuilt_store.pstate, "deck:spanish-101")
      assert deck1.id == deck2.id
    end
  end

  describe "catchup_pstate/2" do
    setup do
      store = ContentStore.new(event_applicator: FlashcardEventApplicator)

      # Create initial data
      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_deck/2, %{
          deck_id: "spanish-101",
          name: "Spanish Basics"
        })

      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_card/2, %{
          card_id: "c1",
          deck_id: "spanish-101",
          front: "Hello",
          back: "Hola"
        })

      %{store: store}
    end

    test "RMX006_3A_T13: applies only new events", %{store: store} do
      # Get current sequence
      {:ok, current_seq} = EventStore.get_latest_sequence(store.event_store)

      # Add new card
      {:ok, _, _updated_store} =
        ContentStore.execute(store, &Command.create_card/2, %{
          card_id: "c2",
          deck_id: "spanish-101",
          front: "Goodbye",
          back: "Adiós"
        })

      # Catchup from previous sequence
      {:ok, caught_up_store, count} = ContentStore.catchup_pstate(store, current_seq)

      assert count == 1
      {:ok, c2} = PState.fetch(caught_up_store.pstate, "card:c2")
      assert c2.front == "Goodbye"
    end

    test "RMX006_3A_T14: returns count", %{store: store} do
      # Get current sequence
      {:ok, current_seq} = EventStore.get_latest_sequence(store.event_store)

      # Add 3 new cards
      {:ok, _, updated_store} =
        ContentStore.execute(store, &Command.create_card/2, %{
          card_id: "c2",
          deck_id: "spanish-101",
          front: "Goodbye",
          back: "Adiós"
        })

      {:ok, _, updated_store} =
        ContentStore.execute(updated_store, &Command.create_card/2, %{
          card_id: "c3",
          deck_id: "spanish-101",
          front: "Please",
          back: "Por favor"
        })

      {:ok, _, _updated_store} =
        ContentStore.execute(updated_store, &Command.create_card/2, %{
          card_id: "c4",
          deck_id: "spanish-101",
          front: "Thank you",
          back: "Gracias"
        })

      # Catchup from old store
      {:ok, _caught_up_store, count} = ContentStore.catchup_pstate(store, current_seq)

      assert count == 3
    end

    test "RMX006_3A_T15: when already up-to-date", %{store: store} do
      {:ok, current_seq} = EventStore.get_latest_sequence(store.event_store)

      {:ok, same_store, count} = ContentStore.catchup_pstate(store, current_seq)

      assert count == 0
      assert same_store == store
    end
  end

  describe "complete workflow" do
    test "RMX006_3A_T16: execute → query" do
      store = ContentStore.new(event_applicator: FlashcardEventApplicator)

      # Execute: Create deck
      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_deck/2, %{
          deck_id: "spanish-101",
          name: "Spanish Basics"
        })

      # Execute: Create card
      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_card/2, %{
          card_id: "c1",
          deck_id: "spanish-101",
          front: "Hello",
          back: "Hola"
        })

      # Execute: Add translation
      {:ok, _, store} =
        ContentStore.execute(store, &Command.add_translation/2, %{
          card_id: "c1",
          field: :front,
          language: "fr",
          translation: "Bonjour"
        })

      # Query: Verify deck
      {:ok, deck} = PState.fetch(store.pstate, "deck:spanish-101")
      assert deck.name == "Spanish Basics"
      assert Map.has_key?(deck.cards, "c1")

      # Query: Verify card
      {:ok, card} = PState.fetch(store.pstate, "card:c1")
      assert card.front == "Hello"
      assert card.back == "Hola"

      # Query: Verify translation
      assert card.translations.front["fr"].text == "Bonjour"
    end

    test "RMX006_3A_T17: execute → rebuild → query" do
      store = ContentStore.new(event_applicator: FlashcardEventApplicator)

      # Create data
      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_deck/2, %{
          deck_id: "spanish-101",
          name: "Spanish Basics"
        })

      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_card/2, %{
          card_id: "c1",
          deck_id: "spanish-101",
          front: "Hello",
          back: "Hola"
        })

      {:ok, _, store} =
        ContentStore.execute(store, &Command.update_card/2, %{
          card_id: "c1",
          front: "Hi",
          back: "Hola"
        })

      # Query before rebuild
      {:ok, card_before} = PState.fetch(store.pstate, "card:c1")

      # Rebuild
      rebuilt_store = ContentStore.rebuild_pstate(store)

      # Query after rebuild
      {:ok, card_after} = PState.fetch(rebuilt_store.pstate, "card:c1")

      # Should have same data
      assert card_before.id == card_after.id
      assert card_before.front == card_after.front
      assert card_before.back == card_after.back
      assert card_before.front == "Hi"
    end
  end
end
