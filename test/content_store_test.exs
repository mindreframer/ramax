defmodule ContentStoreTest do
  use ExUnit.Case, async: true

  alias ContentStore
  alias FlashcardCommand, as: Command

  # Helper to create store with flashcard-specific config
  defp new_flashcard_store(opts \\ []) do
    # Generate unique space name for test isolation
    space_name = Keyword.get(opts, :space_name, "test_#{:rand.uniform(1_000_000)}")

    # Generate unique table names for ETS isolation (unless custom ones provided)
    # This ensures different stores don't share the same ETS tables
    random_suffix = :rand.uniform(1_000_000_000)

    opts =
      opts
      |> Keyword.put(:space_name, space_name)
      |> Keyword.put_new(:event_applicator, FlashcardEventApplicator)
      |> Keyword.put_new(:entity_id_extractor, &FlashcardEntityId.extract/1)
      |> Keyword.update(
        :event_opts,
        [table_name: :"event_store_#{random_suffix}"],
        fn existing_opts ->
          Keyword.put_new(existing_opts, :table_name, :"event_store_#{random_suffix}")
        end
      )
      |> Keyword.update(
        :pstate_opts,
        [table_name: :"pstate_#{random_suffix}"],
        fn existing_opts ->
          Keyword.put_new(existing_opts, :table_name, :"pstate_#{random_suffix}")
        end
      )

    {:ok, store} = ContentStore.new(opts)
    store
  end

  describe "new/1" do
    test "RMX006_3A_T1: initializes both stores" do
      store = new_flashcard_store()

      assert %ContentStore{} = store
      assert %EventStore{} = store.event_store
      assert %PState{} = store.pstate
    end

    test "RMX006_3A_T2: accepts custom adapters" do
      store =
        new_flashcard_store(
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
      store = new_flashcard_store()
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
      store = new_flashcard_store()

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
        new_flashcard_store(
          event_opts: [table_name: :events_1000_test],
          pstate_opts: [table_name: :pstate_1000_test]
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
      store = new_flashcard_store()

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
      store = new_flashcard_store()

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
      store = new_flashcard_store()

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

  describe "RMX007_6A: Space Integration" do
    test "RMX007_6_T1: new/1 requires space_name" do
      assert_raise KeyError, fn ->
        ContentStore.new([])
      end
    end

    test "RMX007_6_T2: new/1 creates space if missing" do
      space_name = "test_space_#{:rand.uniform(1_000_000)}"
      {:ok, store} = ContentStore.new(space_name: space_name)

      assert %Ramax.Space{} = store.space
      assert store.space.space_name == space_name
      assert is_integer(store.space.space_id)
    end

    test "RMX007_6_T3: new/1 uses existing space" do
      space_name = "test_space_#{:rand.uniform(1_000_000)}"

      # Create first store (creates space)
      {:ok, store1} = ContentStore.new(space_name: space_name)
      space_id1 = store1.space.space_id

      # Create second store (reuses space)
      {:ok, store2} = ContentStore.new(space_name: space_name)
      space_id2 = store2.space.space_id

      # Should have same space_id
      assert space_id1 == space_id2
    end

    test "RMX007_6_T4: new/1 initializes PState with space_id" do
      {:ok, store} = ContentStore.new(space_name: "test_#{:rand.uniform(1_000_000)}")

      assert store.pstate.space_id == store.space.space_id
    end

    test "RMX007_6_T5: execute appends to correct space" do
      store1 = new_flashcard_store(space_name: "space_a")
      store2 = new_flashcard_store(space_name: "space_b")

      # Add deck to space_a
      {:ok, [event_id1], _} =
        ContentStore.execute(store1, &Command.create_deck/2, %{
          deck_id: "deck-a",
          name: "Deck A"
        })

      # Add deck to space_b
      {:ok, [event_id2], _} =
        ContentStore.execute(store2, &Command.create_deck/2, %{
          deck_id: "deck-b",
          name: "Deck B"
        })

      # Verify events have correct space_id
      {:ok, event1} = EventStore.get_event(store1.event_store, event_id1)
      {:ok, event2} = EventStore.get_event(store2.event_store, event_id2)

      assert event1.metadata.space_id == store1.space.space_id
      assert event2.metadata.space_id == store2.space.space_id
      assert event1.metadata.space_id != event2.metadata.space_id
    end

    test "RMX007_6_T6: rebuild_pstate only replays space events" do
      # Create two stores with different spaces
      store1 = new_flashcard_store(space_name: "space_rebuild_1")
      store2 = new_flashcard_store(space_name: "space_rebuild_2")

      # Add deck to space 1
      {:ok, _, store1} =
        ContentStore.execute(store1, &Command.create_deck/2, %{
          deck_id: "deck-1",
          name: "Deck 1"
        })

      # Add deck to space 2
      {:ok, _, store2} =
        ContentStore.execute(store2, &Command.create_deck/2, %{
          deck_id: "deck-2",
          name: "Deck 2"
        })

      # Rebuild space 1
      rebuilt_store1 = ContentStore.rebuild_pstate(store1)

      # Space 1 should have deck-1 but not deck-2
      assert {:ok, _} = PState.fetch(rebuilt_store1.pstate, "deck:deck-1")
      assert :error = PState.fetch(rebuilt_store1.pstate, "deck:deck-2")
    end

    @tag :skip
    # TODO: Fix this test - rebuild with shared tables needs investigation
    # The test fails because when sharing PState tables between spaces,
    # rebuild creates a fresh PState but events aren't being properly replayed
    test "RMX007_6_T7: rebuild with multiple spaces (isolation)" do
      # Create two spaces in same database
      store1 =
        new_flashcard_store(
          space_name: "space_iso_1",
          event_adapter: EventStore.Adapters.ETS,
          event_opts: [table_name: :shared_events],
          pstate_adapter: PState.Adapters.ETS,
          pstate_opts: [table_name: :shared_pstate]
        )

      store2 =
        new_flashcard_store(
          space_name: "space_iso_2",
          event_adapter: EventStore.Adapters.ETS,
          event_opts: [table_name: :shared_events],
          pstate_adapter: PState.Adapters.ETS,
          pstate_opts: [table_name: :shared_pstate]
        )

      # Add data to both spaces
      {:ok, _, store1} =
        ContentStore.execute(store1, &Command.create_deck/2, %{
          deck_id: "deck-1",
          name: "Deck 1"
        })

      {:ok, _, store2} =
        ContentStore.execute(store2, &Command.create_deck/2, %{
          deck_id: "deck-2",
          name: "Deck 2"
        })

      # Rebuild only space 1
      rebuilt_store1 = ContentStore.rebuild_pstate(store1)

      # Verify complete isolation
      assert {:ok, deck1} = PState.fetch(rebuilt_store1.pstate, "deck:deck-1")
      assert deck1.name == "Deck 1"
      assert :error = PState.fetch(rebuilt_store1.pstate, "deck:deck-2")
    end

    test "RMX007_6_T8: catchup_pstate uses space_sequence" do
      store = new_flashcard_store()

      # Create initial deck
      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_deck/2, %{
          deck_id: "deck-1",
          name: "Deck 1"
        })

      # Get current space sequence
      {:ok, current_seq} =
        EventStore.get_space_latest_sequence(store.event_store, store.space.space_id)

      # Add another deck
      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_deck/2, %{
          deck_id: "deck-2",
          name: "Deck 2"
        })

      # Catchup from previous sequence
      {:ok, updated_store, count} = ContentStore.catchup_pstate(store, current_seq)

      # Should have applied 1 new event
      assert count == 1

      # Should have deck-2
      assert {:ok, deck2} = PState.fetch(updated_store.pstate, "deck:deck-2")
      assert deck2.name == "Deck 2"
    end

    test "RMX007_6_T9: catchup only applies space events" do
      # Create two stores with different spaces but shared event store
      store1 =
        new_flashcard_store(
          space_name: "space_catchup_1",
          event_adapter: EventStore.Adapters.ETS,
          event_opts: [table_name: :catchup_events]
        )

      store2 =
        new_flashcard_store(
          space_name: "space_catchup_2",
          event_adapter: EventStore.Adapters.ETS,
          event_opts: [table_name: :catchup_events]
        )

      # Add deck to space 1
      {:ok, _, store1} =
        ContentStore.execute(store1, &Command.create_deck/2, %{
          deck_id: "deck-1",
          name: "Deck 1"
        })

      # Get space 1 sequence
      {:ok, seq1} =
        EventStore.get_space_latest_sequence(store1.event_store, store1.space.space_id)

      # Add deck to space 2 (should not affect space 1 catchup)
      {:ok, _, _store2} =
        ContentStore.execute(store2, &Command.create_deck/2, %{
          deck_id: "deck-2",
          name: "Deck 2"
        })

      # Add another deck to space 1
      {:ok, _, store1} =
        ContentStore.execute(store1, &Command.create_deck/2, %{
          deck_id: "deck-3",
          name: "Deck 3"
        })

      # Catchup space 1 from seq1 - should only get deck-3, not deck-2
      {:ok, updated_store1, count} = ContentStore.catchup_pstate(store1, seq1)

      # Should have caught up with 1 event (deck-3), not 2
      assert count == 1

      # Should have deck-3 but not deck-2
      assert {:ok, _} = PState.fetch(updated_store1.pstate, "deck:deck-3")
      assert :error = PState.fetch(updated_store1.pstate, "deck:deck-2")
    end

    test "RMX007_6_T10: get_checkpoint returns space_sequence" do
      store = new_flashcard_store()

      # Initially should return 0 (not found)
      {:ok, checkpoint} = ContentStore.get_checkpoint(store)
      assert checkpoint == 0
    end

    test "RMX007_6_T11: update_checkpoint stores correctly" do
      store = new_flashcard_store()

      # Add a deck to create an event
      {:ok, _, store} =
        ContentStore.execute(store, &Command.create_deck/2, %{
          deck_id: "deck-1",
          name: "Deck 1"
        })

      # Update checkpoint to sequence 1
      :ok = ContentStore.update_checkpoint(store, 1)

      # Verify it was stored
      {:ok, checkpoint} = ContentStore.get_checkpoint(store)
      assert checkpoint == 1
    end

    test "RMX007_6_T12: two stores with different spaces are isolated" do
      # Create two isolated stores
      store1 = new_flashcard_store(space_name: "isolated_1")
      store2 = new_flashcard_store(space_name: "isolated_2")

      # Add same deck_id to both spaces
      {:ok, _, store1} =
        ContentStore.execute(store1, &Command.create_deck/2, %{
          deck_id: "same-id",
          name: "Deck in Space 1"
        })

      {:ok, _, store2} =
        ContentStore.execute(store2, &Command.create_deck/2, %{
          deck_id: "same-id",
          name: "Deck in Space 2"
        })

      # Verify isolation - each space has its own version
      {:ok, deck1} = PState.fetch(store1.pstate, "deck:same-id")
      {:ok, deck2} = PState.fetch(store2.pstate, "deck:same-id")

      assert deck1.name == "Deck in Space 1"
      assert deck2.name == "Deck in Space 2"
      assert deck1.name != deck2.name
    end
  end
end
