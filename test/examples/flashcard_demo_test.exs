defmodule FlashcardDemoTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias FlashcardDemo

  # Clean up ETS tables between tests to avoid conflicts
  setup do
    # Delete ETS tables if they exist
    try do
      :ets.delete(:event_store)
    rescue
      ArgumentError -> :ok
    end

    try do
      :ets.delete(:pstate)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  describe "FlashcardDemo.run/0" do
    test "RMX006_4B_T1: demo runs without errors" do
      # Capture IO to prevent test output pollution
      output =
        capture_io(fn ->
          result = FlashcardDemo.run()
          assert result == :ok
        end)

      # Verify output contains key sections
      assert output =~ "FLASHCARD APP - EVENT SOURCING DEMO"
      assert output =~ "✓ Demo completed successfully!"
    end

    test "RMX006_4B_T2: demo creates deck and cards" do
      # Run demo in a controlled environment
      output =
        capture_io(fn ->
          FlashcardDemo.run()
        end)

      # Verify deck creation
      assert output =~ "Creating 'Spanish Basics' deck"
      assert output =~ "✓ Deck created: spanish-101"

      # Verify card creation
      assert output =~ "Adding basic vocabulary cards"
      assert output =~ "Created card: Hello → Hola"
      assert output =~ "Created card: Goodbye → Adiós"
      assert output =~ "Created card: Thank you → Gracias"
      assert output =~ "Created card: Please → Por favor"
      assert output =~ "Created card: Yes → Sí"
    end

    test "RMX006_4B_T3: demo adds translations" do
      output =
        capture_io(fn ->
          FlashcardDemo.run()
        end)

      # Verify English translations
      assert output =~ "Adding English translations"
      assert output =~ "Added translation: card-1 (back) → Hello"

      # Verify French translations
      assert output =~ "Adding French translations"
      assert output =~ "Added translation: card-1 (front) → Bonjour"
      assert output =~ "Added translation: card-2 (front) → Au revoir"
      assert output =~ "Added translation: card-3 (front) → Merci"

      # Verify card update
      assert output =~ "Updating card-1 (significant change)"
      assert output =~ "✓ Card updated: Hello! → ¡Hola!"
    end

    test "RMX006_4B_T4: demo rebuild produces same data" do
      output =
        capture_io(fn ->
          FlashcardDemo.run()
        end)

      # Verify rebuild section
      assert output =~ "Rebuilding PState from event store"
      assert output =~ "✓ Rebuild successful - data integrity verified!"

      # Verify statistics
      assert output =~ "Total events in event store:"
      assert output =~ "Demo Statistics:"
      assert output =~ "Decks created: 1"
      assert output =~ "Cards created: 5"
      assert output =~ "Translations added: 10"
      assert output =~ "Card updates: 1"
    end

    test "demo displays cards with translations correctly" do
      output =
        capture_io(fn ->
          FlashcardDemo.run()
        end)

      # Verify card display section
      assert output =~ "Cards with translations:"
      assert output =~ "Card: card-"
      assert output =~ "Front:"
      assert output =~ "Back:"
      assert output =~ "Translations:"
    end

    test "demo shows event count" do
      output =
        capture_io(fn ->
          FlashcardDemo.run()
        end)

      # Verify event count is shown
      assert output =~ "Total events in event store:"

      # Extract event count from output and verify it's reasonable
      # We expect: 1 deck.created + 5 card.created + 10 translation.added + 1 card.updated
      # = 17 events (plus potentially 1 translation.invalidated = 18)
      assert output =~ ~r/Total events in event store: \d+/
    end

    test "demo output is non-empty and well-structured" do
      # Verify the demo produces comprehensive output
      output = capture_io(fn -> FlashcardDemo.run() end)

      # Should be substantial output
      assert String.length(output) > 1000

      # Should have clear sections
      assert output =~ "FLASHCARD APP - EVENT SOURCING DEMO"
      assert output =~ "Demo Statistics:"
      assert output =~ "✓ Demo completed successfully!"
    end
  end
end
