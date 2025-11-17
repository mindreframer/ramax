defmodule FlashcardDemoTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias FlashcardDemo

  # Clean up SQLite database files between tests to avoid conflicts
  setup do
    # Delete SQLite database files if they exist
    event_db_path = "/tmp/flashcard_demo_events.db"
    pstate_db_path = "/tmp/flashcard_demo_pstate.db"

    # Force delete files, ignore errors if they don't exist
    File.rm_rf(event_db_path)
    File.rm_rf(pstate_db_path)
    # Also remove any WAL/SHM files
    File.rm_rf("#{event_db_path}-wal")
    File.rm_rf("#{event_db_path}-shm")
    File.rm_rf("#{pstate_db_path}-wal")
    File.rm_rf("#{pstate_db_path}-shm")

    # Clean up after test
    on_exit(fn ->
      File.rm_rf(event_db_path)
      File.rm_rf(pstate_db_path)
      File.rm_rf("#{event_db_path}-wal")
      File.rm_rf("#{event_db_path}-shm")
      File.rm_rf("#{pstate_db_path}-wal")
      File.rm_rf("#{pstate_db_path}-shm")
    end)

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

      # Verify card creation (demo now creates 1500 cards)
      assert output =~ "📝 Adding 1500 vocabulary cards"
      assert output =~ "✓ Created 100 cards"
      assert output =~ "✓ Created 1500 cards"
    end

    test "RMX006_4B_T3: demo adds translations" do
      output =
        capture_io(fn ->
          FlashcardDemo.run()
        end)

      # Verify English translations (now adds 100)
      assert output =~ "🌍 Adding English translations to first 100 cards"
      assert output =~ "✓ Added 100 translations"

      # Verify French translations (now adds 50)
      assert output =~ "🇫🇷 Adding French translations to first 50 cards"
      assert output =~ "✓ Added 50 translations"

      # Verify card update
      assert output =~ "✏️  Updating card-1 (significant change)"
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

      # Verify statistics (updated for new demo scale)
      assert output =~ "📈 Total events in event store:"
      assert output =~ "📊 Demo Statistics:"
      assert output =~ "Decks created: 1"
      assert output =~ "Cards created: 1500"
      assert output =~ "Translations added: 150"
      assert output =~ "Card updates: 1"
    end

    test "demo displays cards with translations correctly" do
      output =
        capture_io(fn ->
          FlashcardDemo.run()
        end)

      # Verify card display section (updated for new output format)
      assert output =~ "📋 Listing all cards"
      assert output =~ "Card: card-"
      assert output =~ "Front:"
      assert output =~ "Back:"
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
