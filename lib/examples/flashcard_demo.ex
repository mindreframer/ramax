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

    # Initialize app with SQLite adapters
    IO.puts("📦 Initializing FlashcardApp with SQLite storage...")
    event_db_path = "/tmp/flashcard_demo_events.db"
    pstate_db_path = "/tmp/flashcard_demo_pstate.db"

    # Clean up old databases if they exist
    if File.exists?(event_db_path), do: File.rm!(event_db_path)
    if File.exists?(pstate_db_path), do: File.rm!(pstate_db_path)

    {time_init, app} = :timer.tc(fn ->
      FlashcardApp.new(
        event_adapter: EventStore.Adapters.SQLite,
        event_opts: [database: event_db_path],
        pstate_adapter: PState.Adapters.SQLite,
        pstate_opts: [path: pstate_db_path]
      )
    end)
    IO.puts("✓ App initialized with SQLite (#{time_init / 1000}ms)")
    IO.puts("  Events: #{event_db_path}")
    IO.puts("  PState: #{pstate_db_path}\n")

    # Create Spanish learning deck
    IO.puts("📚 Creating 'Spanish Basics' deck...")
    {time_deck, {:ok, app}} = :timer.tc(fn -> FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics") end)
    IO.puts("✓ Deck created: spanish-101 (#{time_deck / 1000}ms)\n")

    # Add 1500 cards for performance testing
    num_cards = 1500
    IO.puts("📝 Adding #{num_cards} vocabulary cards...")

    {time_cards, app} =
      :timer.tc(fn ->
        Enum.reduce(1..num_cards, app, fn i, acc_app ->
          card_id = "card-#{i}"
          front = "Word #{i}"
          back = "Palabra #{i}"

          {:ok, updated_app} =
            FlashcardApp.create_card(acc_app, card_id, "spanish-101", front, back)

          # Print progress every 100 cards
          if rem(i, 100) == 0 do
            IO.puts("  ✓ Created #{i} cards...")
          end

          updated_app
        end)
      end)

    IO.puts("  Total time for #{num_cards} cards: #{time_cards / 1000}ms\n")

    # Add English translations to first 100 cards
    num_translations = 100
    IO.puts("🌍 Adding English translations to first #{num_translations} cards...")

    {time_en_trans, app} =
      :timer.tc(fn ->
        Enum.reduce(1..num_translations, app, fn i, acc_app ->
          card_id = "card-#{i}"
          {:ok, updated_app} =
            FlashcardApp.add_translation(acc_app, card_id, :back, "en", "Word #{i}")

          if rem(i, 20) == 0 do
            IO.puts("  ✓ Added #{i} translations...")
          end

          updated_app
        end)
      end)

    IO.puts("  Total time for #{num_translations} English translations: #{time_en_trans / 1000}ms\n")

    # Add French translations to first 50 cards
    num_fr_translations = 50
    IO.puts("🇫🇷 Adding French translations to first #{num_fr_translations} cards...")

    {time_fr_trans, app} =
      :timer.tc(fn ->
        Enum.reduce(1..num_fr_translations, app, fn i, acc_app ->
          card_id = "card-#{i}"
          {:ok, updated_app} =
            FlashcardApp.add_translation(acc_app, card_id, :front, "fr", "Mot #{i}")

          if rem(i, 10) == 0 do
            IO.puts("  ✓ Added #{i} translations...")
          end

          updated_app
        end)
      end)

    IO.puts("  Total time for #{num_fr_translations} French translations: #{time_fr_trans / 1000}ms\n")

    # Update a card to demonstrate translation invalidation
    IO.puts("✏️  Updating card-1 (significant change)...")
    {time_update, {:ok, app}} = :timer.tc(fn -> FlashcardApp.update_card(app, "card-1", "Hello!", "¡Hola!") end)
    IO.puts("✓ Card updated: Hello! → ¡Hola! (#{time_update / 1000}ms)")
    IO.puts("  (Translations may be invalidated due to significant change)\n")

    # Query and display deck information
    IO.puts("📊 Querying deck information...")
    {time_query, {:ok, deck}} = :timer.tc(fn -> FlashcardApp.get_deck(app, "spanish-101") end)
    IO.puts("Deck: #{deck.name}")
    IO.puts("Cards in deck: #{map_size(deck.cards)} (query took #{time_query / 1000}ms)\n")

    # Display sample cards with translations (first 5 only)
    IO.puts("📋 Listing all cards (#{num_cards} total):")
    {time_list, {:ok, cards}} = :timer.tc(fn -> FlashcardApp.list_deck_cards(app, "spanish-101") end)
    IO.puts("  (Listing #{length(cards)} cards took #{time_list / 1000}ms)")
    IO.puts("  Showing first 5 cards:\n")

    cards
    |> Enum.take(5)
    |> Enum.each(fn card ->
      IO.puts("  Card: #{card.id}")
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

      IO.puts("")
    end)

    # Show event count
    event_count = FlashcardApp.get_event_count(app)
    IO.puts("📈 Total events in event store: #{event_count}\n")

    # Rebuild PState from events
    IO.puts("🔄 Rebuilding PState from event store...")
    {time_rebuild_prep, {deck_before_rebuild, cards_before_rebuild}} = :timer.tc(fn ->
      {:ok, deck} = FlashcardApp.get_deck(app, "spanish-101")
      {:ok, cards} = FlashcardApp.list_deck_cards(app, "spanish-101")
      {deck, cards}
    end)

    {time_rebuild, app} = :timer.tc(fn -> FlashcardApp.rebuild(app) end)
    IO.puts("  Rebuild took #{time_rebuild / 1000}ms")

    {time_verify, {deck_after_rebuild, cards_after_rebuild}} = :timer.tc(fn ->
      {:ok, deck} = FlashcardApp.get_deck(app, "spanish-101")
      {:ok, cards} = FlashcardApp.list_deck_cards(app, "spanish-101")
      {deck, cards}
    end)

    # Verify data integrity
    if deck_before_rebuild == deck_after_rebuild and cards_before_rebuild == cards_after_rebuild do
      IO.puts("✓ Rebuild successful - data integrity verified! (verification took #{time_verify / 1000}ms)")
    else
      IO.puts("⚠️  Warning: Data mismatch after rebuild")
    end

    IO.puts("")

    # Print statistics
    IO.puts("📊 Demo Statistics:")
    IO.puts("  Decks created: 1")
    IO.puts("  Cards created: #{num_cards}")
    IO.puts("  Translations added: #{num_translations + num_fr_translations}")
    IO.puts("  Card updates: 1")
    IO.puts("  Total events: #{event_count}")
    IO.puts("  PState rebuilds: 1")

    IO.puts("\n⏱️  Timing Breakdown:")
    IO.puts("  Initialization: #{time_init / 1000}ms")
    IO.puts("  Create deck: #{time_deck / 1000}ms")
    IO.puts("  Create cards (#{num_cards}): #{time_cards / 1000}ms (#{Float.round(num_cards / (time_cards / 1_000_000), 1)} cards/sec)")
    IO.puts("  English translations (#{num_translations}): #{time_en_trans / 1000}ms")
    IO.puts("  French translations (#{num_fr_translations}): #{time_fr_trans / 1000}ms")
    IO.puts("  Update card: #{time_update / 1000}ms")
    IO.puts("  Query deck: #{time_query / 1000}ms")
    IO.puts("  List cards: #{time_list / 1000}ms")
    IO.puts("  Rebuild PState: #{time_rebuild / 1000}ms")
    IO.puts("  Verify rebuild: #{time_verify / 1000}ms")

    total_time = time_init + time_deck + time_cards + time_en_trans + time_fr_trans +
                 time_update + time_query + time_list + time_rebuild + time_verify
    IO.puts("  TOTAL: #{total_time / 1000}ms")

    IO.puts("\n========================================")
    IO.puts("✓ Demo completed successfully!")
    IO.puts("========================================\n")

    :ok
  end
end
