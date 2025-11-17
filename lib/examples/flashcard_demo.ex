defmodule FlashcardDemo do
  @moduledoc """
  Interactive demonstration of the FlashcardApp event sourcing system.

  This demo showcases the complete event sourcing workflow:

  - Creating decks and flashcards
  - Adding multi-language translations
  - Updating card content
  - Querying cards and decks
  - Rebuilding PState from events
  - Verifying data integrity after rebuild

  ## Running the Demo

      FlashcardDemo.run()

  The demo will create a Spanish learning deck with basic vocabulary,
  add translations in English and French, update a card to demonstrate
  translation invalidation, and then rebuild the PState to verify that
  all data is correctly restored from events.

  ## What the Demo Shows

  1. **Event Sourcing**: All changes are captured as immutable events
  2. **Command Validation**: Invalid operations are rejected with clear errors
  3. **Translation Management**: Multi-language support for flashcards
  4. **PState Rebuild**: Complete state reconstruction from event history
  5. **Data Integrity**: Rebuilt state matches current state exactly

  ## Output

  The demo prints detailed information about each operation, showing:

  - Deck and card creation
  - Translation additions
  - Event counts
  - Card details with translations
  - Rebuild verification

  ## References

  - ADR004: PState Materialization from Events
  - RMX006: Event Application to PState Epic
  """

  alias FlashcardApp

  @doc """
  Run the interactive flashcard demo.

  This function executes a complete demo scenario showing all features
  of the FlashcardApp event sourcing system.

  ## Returns

  - `:ok` - Demo completed successfully

  ## Examples

      FlashcardDemo.run()
      # Prints:
      # ========================================
      # FLASHCARD APP - EVENT SOURCING DEMO
      # ========================================
      # ...
      # ✓ Demo completed successfully!

  """
  @spec run() :: :ok
  def run do
    IO.puts("\n========================================")
    IO.puts("FLASHCARD APP - EVENT SOURCING DEMO")
    IO.puts("========================================\n")

    # Initialize app with in-memory adapters
    IO.puts("📦 Initializing FlashcardApp with in-memory storage...")
    app = FlashcardApp.new()
    IO.puts("✓ App initialized\n")

    # Create Spanish learning deck
    IO.puts("📚 Creating 'Spanish Basics' deck...")
    {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
    IO.puts("✓ Deck created: spanish-101\n")

    # Add 5 basic vocabulary cards
    IO.puts("📝 Adding basic vocabulary cards...")

    card_data = [
      {"card-1", "Hello", "Hola"},
      {"card-2", "Goodbye", "Adiós"},
      {"card-3", "Thank you", "Gracias"},
      {"card-4", "Please", "Por favor"},
      {"card-5", "Yes", "Sí"}
    ]

    app =
      Enum.reduce(card_data, app, fn {card_id, front, back}, acc_app ->
        {:ok, updated_app} =
          FlashcardApp.create_card(acc_app, card_id, "spanish-101", front, back)

        IO.puts("  ✓ Created card: #{front} → #{back}")
        updated_app
      end)

    IO.puts("")

    # Add English translations to back fields (for Spanish → English)
    IO.puts("🌍 Adding English translations...")

    english_translations = [
      {"card-1", :back, "en", "Hello"},
      {"card-2", :back, "en", "Goodbye"},
      {"card-3", :back, "en", "Thank you"},
      {"card-4", :back, "en", "Please"},
      {"card-5", :back, "en", "Yes"}
    ]

    app =
      Enum.reduce(english_translations, app, fn {card_id, field, lang, translation}, acc_app ->
        {:ok, updated_app} =
          FlashcardApp.add_translation(acc_app, card_id, field, lang, translation)

        IO.puts("  ✓ Added translation: #{card_id} (#{field}) → #{translation}")
        updated_app
      end)

    IO.puts("")

    # Add French translations
    IO.puts("🇫🇷 Adding French translations...")

    french_translations = [
      {"card-1", :front, "fr", "Bonjour"},
      {"card-2", :front, "fr", "Au revoir"},
      {"card-3", :front, "fr", "Merci"},
      {"card-4", :front, "fr", "S'il vous plaît"},
      {"card-5", :front, "fr", "Oui"}
    ]

    app =
      Enum.reduce(french_translations, app, fn {card_id, field, lang, translation}, acc_app ->
        {:ok, updated_app} =
          FlashcardApp.add_translation(acc_app, card_id, field, lang, translation)

        IO.puts("  ✓ Added translation: #{card_id} (#{field}) → #{translation}")
        updated_app
      end)

    IO.puts("")

    # Update a card to demonstrate translation invalidation
    IO.puts("✏️  Updating card-1 (significant change)...")
    {:ok, app} = FlashcardApp.update_card(app, "card-1", "Hello!", "¡Hola!")
    IO.puts("✓ Card updated: Hello! → ¡Hola!")
    IO.puts("  (Translations may be invalidated due to significant change)\n")

    # Query and display deck information
    IO.puts("📊 Querying deck information...")
    {:ok, deck} = FlashcardApp.get_deck(app, "spanish-101")
    IO.puts("Deck: #{deck.name}")
    IO.puts("Cards in deck: #{map_size(deck.cards)}\n")

    # Display cards with translations
    IO.puts("📋 Cards with translations:")
    {:ok, cards} = FlashcardApp.list_deck_cards(app, "spanish-101")

    Enum.each(cards, fn card ->
      IO.puts("\n  Card: #{card.id}")
      IO.puts("    Front: #{card.front}")
      IO.puts("    Back: #{card.back}")

      if map_size(card.translations) > 0 do
        IO.puts("    Translations:")

        Enum.each(card.translations, fn
          {:_invalidated, true} ->
            IO.puts("      ⚠️  Translations invalidated")

          {field, langs} when is_map(langs) ->
            Enum.each(langs, fn {lang, trans_data} ->
              IO.puts("      #{field}/#{lang}: #{trans_data.text}")
            end)

          _ ->
            :ok
        end)
      end
    end)

    IO.puts("")

    # Show event count
    event_count = FlashcardApp.get_event_count(app)
    IO.puts("📈 Total events in event store: #{event_count}\n")

    # Rebuild PState from events
    IO.puts("🔄 Rebuilding PState from event store...")
    {:ok, deck_before_rebuild} = FlashcardApp.get_deck(app, "spanish-101")
    {:ok, cards_before_rebuild} = FlashcardApp.list_deck_cards(app, "spanish-101")

    app = FlashcardApp.rebuild(app)

    {:ok, deck_after_rebuild} = FlashcardApp.get_deck(app, "spanish-101")
    {:ok, cards_after_rebuild} = FlashcardApp.list_deck_cards(app, "spanish-101")

    # Verify data integrity
    if deck_before_rebuild == deck_after_rebuild and cards_before_rebuild == cards_after_rebuild do
      IO.puts("✓ Rebuild successful - data integrity verified!")
    else
      IO.puts("⚠️  Warning: Data mismatch after rebuild")
    end

    IO.puts("")

    # Print statistics
    IO.puts("📊 Demo Statistics:")
    IO.puts("  Decks created: 1")
    IO.puts("  Cards created: 5")
    IO.puts("  Translations added: 10")
    IO.puts("  Card updates: 1")
    IO.puts("  Total events: #{event_count}")
    IO.puts("  PState rebuilds: 1")

    IO.puts("\n========================================")
    IO.puts("✓ Demo completed successfully!")
    IO.puts("========================================\n")

    :ok
  end
end
