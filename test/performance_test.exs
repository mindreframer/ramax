# Performance test to identify scaling issues
# Run with: mix run test/performance_test.exs

IO.puts("\n========================================")
IO.puts("PERFORMANCE SCALING TEST")
IO.puts("========================================\n")

card_counts = [50, 100, 200, 500]

results = Enum.map(card_counts, fn count ->
  IO.puts("Testing with #{count} cards...")

  # Setup
  app = FlashcardApp.new()
  {:ok, app} = FlashcardApp.create_deck(app, "deck-1", "Test Deck")

  # Create cards
  {create_time, app} = :timer.tc(fn ->
    Enum.reduce(1..count, app, fn i, acc ->
      {:ok, updated} = FlashcardApp.create_card(acc, "card-#{i}", "deck-1", "Front #{i}", "Back #{i}")
      updated
    end)
  end)

  # Test translation (middle card)
  mid_card = "card-#{div(count, 2)}"
  {trans_time, {:ok, app}} = :timer.tc(fn ->
    FlashcardApp.add_translation(app, mid_card, :back, "en", "Translation")
  end)

  # Test update
  {update_time, _} = :timer.tc(fn ->
    FlashcardApp.update_card(app, "card-1", "Updated Front", "Updated Back")
  end)

  result = %{
    count: count,
    create_total: create_time,
    create_per_card: create_time / count,
    translation: trans_time,
    update: update_time
  }

  IO.puts("  Create #{count} cards: #{Float.round(create_time / 1000, 2)}ms (#{Float.round(result.create_per_card / 1000, 3)}ms/card)")
  IO.puts("  Add translation: #{Float.round(trans_time / 1000, 2)}ms")
  IO.puts("  Update card: #{Float.round(update_time / 1000, 2)}ms\n")

  result
end)

IO.puts("========================================")
IO.puts("SCALING ANALYSIS")
IO.puts("========================================\n")

IO.puts("Translation time growth:")
Enum.each(results, fn r ->
  IO.puts("  #{r.count} cards: #{Float.round(r.translation / 1000, 2)}ms")
end)

IO.puts("\nUpdate time growth:")
Enum.each(results, fn r ->
  IO.puts("  #{r.count} cards: #{Float.round(r.update / 1000, 2)}ms")
end)

# Calculate if it's O(n) or O(n²)
if length(results) >= 2 do
  [first, second | _] = results

  ratio_n = second.count / first.count
  ratio_trans = second.translation / first.translation
  ratio_update = second.update / first.update

  IO.puts("\nFrom #{first.count} to #{second.count} cards (#{Float.round(ratio_n, 1)}x):")
  IO.puts("  Translation slowdown: #{Float.round(ratio_trans, 1)}x")
  IO.puts("  Update slowdown: #{Float.round(ratio_update, 1)}x")

  cond do
    ratio_trans > ratio_n * 1.5 ->
      IO.puts("  ⚠️  Translation appears to be worse than O(n) - likely O(n²) or worse!")
    ratio_trans > ratio_n * 0.8 ->
      IO.puts("  ⚠️  Translation appears to be O(n) - scales linearly with cards")
    true ->
      IO.puts("  ✓ Translation is sub-linear (good!)")
  end

  cond do
    ratio_update > ratio_n * 1.5 ->
      IO.puts("  ⚠️  Update appears to be worse than O(n) - likely O(n²) or worse!")
    ratio_update > ratio_n * 0.8 ->
      IO.puts("  ⚠️  Update appears to be O(n) - scales linearly with cards")
    true ->
      IO.puts("  ✓ Update is sub-linear (good!)")
  end
end

IO.puts("\n========================================\n")
