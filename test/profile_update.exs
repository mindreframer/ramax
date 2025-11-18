# Deep profiling of update_card to find O(n²) bottleneck
# Run with: mix run test/profile_update.exs

IO.puts("\n========================================")
IO.puts("PROFILING update_card BOTTLENECK")
IO.puts("========================================\n")

# Setup with 200 cards (enough to show the problem)
IO.puts("Setting up test with 200 cards...")
app = FlashcardApp.new(space_name: "profile_test")
{:ok, app} = FlashcardApp.create_deck(app, "deck-1", "Test")

app =
  Enum.reduce(1..200, app, fn i, acc ->
    {:ok, updated} =
      FlashcardApp.create_card(acc, "card-#{i}", "deck-1", "Front #{i}", "Back #{i}")

    updated
  end)

IO.puts("✓ Setup complete\n")

# Profile with eflambe (generates flame graph)
IO.puts("Profiling with eflambe (flame graph)...")

:eflambe.capture(
  fn ->
    # Run update 5 times to get good sampling
    Enum.reduce(1..5, app, fn i, acc ->
      {:ok, updated} = FlashcardApp.update_card(acc, "card-1", "Updated #{i}", "Back #{i}")
      updated
    end)
  end,
  [output: "/tmp/update_card_flame.bggg"],
  []
)

IO.puts("✓ Flame graph saved to /tmp/update_card_flame.bggg")
IO.puts("  View with: https://www.speedscope.app/ (upload the .bggg file)")
IO.puts("")

# Manual instrumentation - add timing to key functions
IO.puts("Manual timing breakdown:")
IO.puts("Running update_card with instrumentation...\n")

defmodule Profiler do
  def measure(label, func) do
    {time, result} = :timer.tc(func)
    IO.puts("  #{label}: #{Float.round(time / 1000, 3)}ms")
    result
  end
end

# Instrument the update flow
{total_time, _} =
  :timer.tc(fn ->
    # This is what FlashcardApp.update_card does internally
    params = %{card_id: "card-1", front: "New Front", back: "New Back"}

    Profiler.measure("Total update_card", fn ->
      ContentStore.execute(app.store, &Command.update_card/2, params)
    end)
  end)

IO.puts("\nTotal measured time: #{Float.round(total_time / 1000, 3)}ms")

IO.puts("\n========================================")
IO.puts("ANALYSIS")
IO.puts("========================================\n")

IO.puts("The flame graph will show you exactly which functions")
IO.puts("are consuming the most time. Look for:")
IO.puts("  - Wide bars = functions taking lots of time")
IO.puts("  - Deep stacks = many nested function calls")
IO.puts("")
IO.puts("Common suspects:")
IO.puts("  1. ContentStore.apply_events - rebuilding PState for every command")
IO.puts("  2. Map/Enum operations over all cards")
IO.puts("  3. ETS scans instead of lookups")
IO.puts("")
