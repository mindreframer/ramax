defmodule ContentStore.EventApplicatorTest do
  use ExUnit.Case, async: true

  alias ContentStore.EventApplicator
  alias PState.Ref

  # Helper to create fresh PState for tests
  defp new_pstate do
    PState.new("content:root",
      adapter: PState.Adapters.ETS,
      adapter_opts: [table_name: :"test_event_applicator_#{:erlang.unique_integer([:positive])}"]
    )
  end

  # Helper to create events with metadata
  defp make_event(event_type, payload, opts \\ []) do
    %{
      metadata: %{
        event_id: Keyword.get(opts, :event_id, 1),
        entity_id: Keyword.get(opts, :entity_id, "test:entity"),
        event_type: event_type,
        timestamp: Keyword.get(opts, :timestamp, ~U[2025-01-17 12:00:00Z]),
        causation_id: Keyword.get(opts, :causation_id),
        correlation_id: Keyword.get(opts, :correlation_id)
      },
      payload: payload
    }
  end

  describe "apply_event/2 - deck.created" do
    # RMX006_2A_T1
    test "creates deck in PState" do
      pstate = new_pstate()
      event = make_event("deck.created", %{deck_id: "d1", name: "Spanish 101"})

      pstate = EventApplicator.apply_event(pstate, event)

      assert {:ok, deck} = PState.fetch(pstate, "deck:d1")
      assert deck.id == "d1"
      assert deck.name == "Spanish 101"
    end

    # RMX006_2A_T2
    test "deck.created sets correct fields" do
      pstate = new_pstate()
      timestamp = ~U[2025-01-17 15:30:45Z]

      event =
        make_event("deck.created", %{deck_id: "spanish", name: "Spanish Basics"},
          timestamp: timestamp
        )

      pstate = EventApplicator.apply_event(pstate, event)

      {:ok, deck} = PState.fetch(pstate, "deck:spanish")
      assert deck.id == "spanish"
      assert deck.name == "Spanish Basics"
      assert deck.cards == %{}
      assert deck.created_at == DateTime.to_unix(timestamp)
    end
  end

  describe "apply_event/2 - card.created" do
    # RMX006_2A_T3
    test "creates card in PState" do
      pstate = new_pstate()
      # Create deck first
      pstate = put_in(pstate["deck:d1"], %{id: "d1", name: "Test", cards: %{}})

      event =
        make_event("card.created", %{
          card_id: "c1",
          deck_id: "d1",
          front: "Hello",
          back: "Hola"
        })

      pstate = EventApplicator.apply_event(pstate, event)

      assert {:ok, card} = PState.fetch(pstate, "card:c1")
      assert card.id == "c1"
      assert card.front == "Hello"
      assert card.back == "Hola"
    end

    # RMX006_2A_T4
    test "card.created creates card in current schema shape" do
      pstate = new_pstate()
      pstate = put_in(pstate["deck:d1"], %{id: "d1", name: "Test", cards: %{}})

      timestamp = ~U[2025-01-17 16:00:00Z]

      event =
        make_event(
          "card.created",
          %{card_id: "c1", deck_id: "d1", front: "Hello", back: "Hola"},
          timestamp: timestamp
        )

      pstate = EventApplicator.apply_event(pstate, event)

      {:ok, card} = PState.fetch(pstate, "card:c1")
      assert card.id == "c1"
      assert card.front == "Hello"
      assert card.back == "Hola"
      # PState auto-resolves refs, so card.deck will be the actual deck object
      # Check that the reference was stored correctly by verifying the raw cache
      assert pstate.cache["card:c1"].deck == %PState.Ref{key: "deck:d1"}
      assert card.translations == %{}
      assert card.created_at == DateTime.to_unix(timestamp)
    end

    # RMX006_2A_T5
    test "card.created adds card to deck" do
      pstate = new_pstate()
      pstate = put_in(pstate["deck:d1"], %{id: "d1", name: "Test", cards: %{}})

      event =
        make_event("card.created", %{
          card_id: "c1",
          deck_id: "d1",
          front: "Hello",
          back: "Hola"
        })

      pstate = EventApplicator.apply_event(pstate, event)

      {:ok, deck} = PState.fetch(pstate, "deck:d1")
      assert Map.has_key?(deck.cards, "c1")
      # PState auto-resolves refs, check the raw cache for the actual Ref
      assert pstate.cache["deck:d1"].cards["c1"] == %PState.Ref{key: "card:c1"}
    end

    # RMX006_2A_T6
    test "card.created creates PState.Ref for deck" do
      pstate = new_pstate()
      pstate = put_in(pstate["deck:spanish"], %{id: "spanish", name: "Spanish", cards: %{}})

      event =
        make_event("card.created", %{
          card_id: "c1",
          deck_id: "spanish",
          front: "Hello",
          back: "Hola"
        })

      pstate = EventApplicator.apply_event(pstate, event)

      # PState auto-resolves refs, check the raw cache for the actual Ref
      assert pstate.cache["card:c1"].deck == Ref.new(:deck, "spanish")
    end
  end

  describe "apply_event/2 - card.updated" do
    # RMX006_2A_T7
    test "updates card fields" do
      pstate = new_pstate()

      pstate =
        put_in(pstate["card:c1"], %{
          id: "c1",
          front: "Hello",
          back: "Hola",
          translations: %{},
          created_at: 1_234_567_890
        })

      event =
        make_event("card.updated", %{
          card_id: "c1",
          front: "Hi",
          back: "Hola (informal)"
        })

      pstate = EventApplicator.apply_event(pstate, event)

      {:ok, card} = PState.fetch(pstate, "card:c1")
      assert card.front == "Hi"
      assert card.back == "Hola (informal)"
    end

    # RMX006_2A_T8
    test "card.updated sets updated_at timestamp" do
      pstate = new_pstate()

      pstate =
        put_in(pstate["card:c1"], %{
          id: "c1",
          front: "Hello",
          back: "Hola",
          translations: %{},
          created_at: 1_234_567_890
        })

      timestamp = ~U[2025-01-17 17:00:00Z]

      event =
        make_event(
          "card.updated",
          %{card_id: "c1", front: "Hi", back: "Hola"},
          timestamp: timestamp
        )

      pstate = EventApplicator.apply_event(pstate, event)

      {:ok, card} = PState.fetch(pstate, "card:c1")
      assert card.updated_at == DateTime.to_unix(timestamp)
    end
  end

  describe "apply_event/2 - card.translation.added" do
    # RMX006_2A_T9
    test "adds translation to card" do
      pstate = new_pstate()

      pstate =
        put_in(pstate["card:c1"], %{
          id: "c1",
          front: "Hello",
          back: "Hola",
          translations: %{},
          created_at: 1_234_567_890
        })

      event =
        make_event("card.translation.added", %{
          card_id: "c1",
          field: :front,
          language: "fr",
          translation: "Bonjour"
        })

      pstate = EventApplicator.apply_event(pstate, event)

      {:ok, card} = PState.fetch(pstate, "card:c1")
      assert card.translations[:front]["fr"].text == "Bonjour"
    end

    # RMX006_2A_T10
    test "translation.added creates nested structure" do
      pstate = new_pstate()

      pstate =
        put_in(pstate["card:c1"], %{
          id: "c1",
          front: "Hello",
          back: "Hola",
          translations: %{},
          created_at: 1_234_567_890
        })

      # Add first translation
      event1 =
        make_event("card.translation.added", %{
          card_id: "c1",
          field: :front,
          language: "fr",
          translation: "Bonjour"
        })

      pstate = EventApplicator.apply_event(pstate, event1)

      # Add second translation to same field, different language
      event2 =
        make_event("card.translation.added", %{
          card_id: "c1",
          field: :front,
          language: "de",
          translation: "Hallo"
        })

      pstate = EventApplicator.apply_event(pstate, event2)

      # Add translation to different field
      event3 =
        make_event("card.translation.added", %{
          card_id: "c1",
          field: :back,
          language: "fr",
          translation: "Salut"
        })

      pstate = EventApplicator.apply_event(pstate, event3)

      {:ok, card} = PState.fetch(pstate, "card:c1")
      assert card.translations[:front]["fr"].text == "Bonjour"
      assert card.translations[:front]["de"].text == "Hallo"
      assert card.translations[:back]["fr"].text == "Salut"
    end

    # RMX006_2A_T11
    test "translation.added sets added_at timestamp" do
      pstate = new_pstate()

      pstate =
        put_in(pstate["card:c1"], %{
          id: "c1",
          front: "Hello",
          back: "Hola",
          translations: %{},
          created_at: 1_234_567_890
        })

      timestamp = ~U[2025-01-17 18:00:00Z]

      event =
        make_event(
          "card.translation.added",
          %{card_id: "c1", field: :front, language: "fr", translation: "Bonjour"},
          timestamp: timestamp
        )

      pstate = EventApplicator.apply_event(pstate, event)

      {:ok, card} = PState.fetch(pstate, "card:c1")
      assert card.translations[:front]["fr"].added_at == DateTime.to_unix(timestamp)
    end
  end

  describe "apply_event/2 - card.translations.invalidated" do
    # RMX006_2A_T12
    test "sets invalidation flag" do
      pstate = new_pstate()

      pstate =
        put_in(pstate["card:c1"], %{
          id: "c1",
          front: "Hello",
          back: "Hola",
          translations: %{
            front: %{"fr" => %{text: "Bonjour", added_at: 1_234_567_890}}
          },
          created_at: 1_234_567_890
        })

      event = make_event("card.translations.invalidated", %{card_id: "c1"})

      pstate = EventApplicator.apply_event(pstate, event)

      {:ok, card} = PState.fetch(pstate, "card:c1")
      assert card.translations[:_invalidated] == true
    end
  end

  describe "apply_event/2 - unknown events" do
    # RMX006_2A_T13
    test "unknown event type is ignored" do
      pstate = new_pstate()
      pstate = put_in(pstate["test:data"], %{value: 42})

      event = make_event("unknown.event.type", %{some: "data"})

      pstate_after = EventApplicator.apply_event(pstate, event)

      # PState unchanged
      assert pstate == pstate_after
    end
  end

  describe "apply_events/2" do
    # RMX006_2A_T14
    test "applies multiple events in order" do
      pstate = new_pstate()

      events = [
        make_event("deck.created", %{deck_id: "d1", name: "Spanish"}, event_id: 1),
        make_event("card.created", %{card_id: "c1", deck_id: "d1", front: "Hello", back: "Hola"},
          event_id: 2
        ),
        make_event(
          "card.created",
          %{card_id: "c2", deck_id: "d1", front: "Goodbye", back: "Adiós"},
          event_id: 3
        )
      ]

      pstate = EventApplicator.apply_events(pstate, events)

      assert {:ok, deck} = PState.fetch(pstate, "deck:d1")
      assert {:ok, card1} = PState.fetch(pstate, "card:c1")
      assert {:ok, card2} = PState.fetch(pstate, "card:c2")

      assert deck.name == "Spanish"
      assert card1.front == "Hello"
      assert card2.front == "Goodbye"
      assert Map.keys(deck.cards) |> Enum.sort() == ["c1", "c2"]
    end

    # RMX006_2A_T15
    test "apply_events is idempotent for same events" do
      pstate = new_pstate()

      events = [
        make_event("deck.created", %{deck_id: "d1", name: "Spanish"})
      ]

      pstate1 = EventApplicator.apply_events(pstate, events)
      pstate2 = EventApplicator.apply_events(pstate, events)

      # Applying same events to fresh PState produces same result
      assert pstate1 == pstate2
    end

    # RMX006_2A_T16
    test "old event creates new schema shape" do
      # Simulating an old event that doesn't have translations field in payload
      # but the current schema expects it
      pstate = new_pstate()
      pstate = put_in(pstate["deck:d1"], %{id: "d1", name: "Test", cards: %{}})

      # Old v1 event (imagine this was stored years ago)
      old_card_created_event =
        make_event("card.created", %{
          card_id: "c1",
          deck_id: "d1",
          front: "Hello",
          back: "Hola"
          # Note: no translations field in old event payload
        })

      pstate = EventApplicator.apply_event(pstate, old_card_created_event)

      {:ok, card} = PState.fetch(pstate, "card:c1")

      # Even though old event didn't have translations, new schema shape includes it
      assert Map.has_key?(card, :translations)
      assert card.translations == %{}
      assert Map.has_key?(card, :deck)
      # PState auto-resolves refs, check the raw cache for the actual Ref
      assert pstate.cache["card:c1"].deck == Ref.new(:deck, "d1")
    end
  end

  describe "complex scenarios" do
    test "complete workflow: create deck, add cards, update, translate" do
      pstate = new_pstate()

      events = [
        # Create deck
        make_event("deck.created", %{deck_id: "spanish", name: "Spanish 101"},
          event_id: 1,
          timestamp: ~U[2025-01-17 10:00:00Z]
        ),
        # Add first card
        make_event(
          "card.created",
          %{card_id: "c1", deck_id: "spanish", front: "Hello", back: "Hola"},
          event_id: 2,
          timestamp: ~U[2025-01-17 10:01:00Z]
        ),
        # Add second card
        make_event(
          "card.created",
          %{card_id: "c2", deck_id: "spanish", front: "Goodbye", back: "Adiós"},
          event_id: 3,
          timestamp: ~U[2025-01-17 10:02:00Z]
        ),
        # Update first card
        make_event("card.updated", %{card_id: "c1", front: "Hi", back: "Hola"},
          event_id: 4,
          timestamp: ~U[2025-01-17 10:03:00Z]
        ),
        # Add translation
        make_event(
          "card.translation.added",
          %{card_id: "c1", field: :front, language: "fr", translation: "Salut"},
          event_id: 5,
          timestamp: ~U[2025-01-17 10:04:00Z]
        ),
        # Invalidate translations
        make_event("card.translations.invalidated", %{card_id: "c1"},
          event_id: 6,
          timestamp: ~U[2025-01-17 10:05:00Z]
        )
      ]

      pstate = EventApplicator.apply_events(pstate, events)

      # Verify deck
      {:ok, deck} = PState.fetch(pstate, "deck:spanish")
      assert deck.name == "Spanish 101"
      assert map_size(deck.cards) == 2

      # Verify card 1 (updated and translated)
      {:ok, card1} = PState.fetch(pstate, "card:c1")
      # Updated
      assert card1.front == "Hi"
      assert card1.back == "Hola"
      assert card1.translations[:front]["fr"].text == "Salut"
      assert card1.translations[:_invalidated] == true

      # Verify card 2 (unchanged)
      {:ok, card2} = PState.fetch(pstate, "card:c2")
      assert card2.front == "Goodbye"
      assert card2.back == "Adiós"
    end
  end
end
