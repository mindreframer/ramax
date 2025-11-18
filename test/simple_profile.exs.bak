# Simple focused profiling to find exact bottleneck
# Run with: mix run test/simple_profile.exs

IO.puts("\n========================================")
IO.puts("PROFILING: Revert to OLD code temporarily")
IO.puts("========================================\n")

IO.puts("We need to revert event_applicator.ex temporarily to see")
IO.puts("where EXACTLY the time goes in the original broken version.")
IO.puts("")
IO.puts("Let me create a minimal reproduction:")
IO.puts("")

# Create setup with 200 cards
app = FlashcardApp.new()
{:ok, app} = FlashcardApp.create_deck(app, "deck-1", "Test")

IO.puts("Creating 200 cards...")

{time_create, app} =
  :timer.tc(fn ->
    Enum.reduce(1..200, app, fn i, acc ->
      {:ok, updated} = FlashcardApp.create_card(acc, "card-#{i}", "deck-1", "F#{i}", "B#{i}")
      updated
    end)
  end)

IO.puts("✓ Created 200 cards in #{Float.round(time_create / 1000, 2)}ms\n")

# Now let's trace EXACTLY what happens in update
IO.puts("Tracing update_card execution...")
IO.puts("")

# Break down the update into steps
params = %{card_id: "card-100", front: "Updated", back: "Updated"}

IO.puts("STEP 1: Command.update_card (validates and generates events)")

{time_cmd, result} =
  :timer.tc(fn ->
    ContentStore.Command.update_card(app.store.pstate, params)
  end)

IO.puts("  Time: #{Float.round(time_cmd / 1000, 3)}ms")
{:ok, event_specs} = result
IO.puts("  Generated #{length(event_specs)} event(s)\n")

IO.puts("STEP 2: Append events to EventStore")

{time_append, {event_ids, updated_event_store}} =
  :timer.tc(fn ->
    Enum.reduce(event_specs, {[], app.store.event_store}, fn {event_type, payload},
                                                             {ids, store} ->
      {:ok, event_id, new_store} =
        EventStore.append(
          store,
          "card:#{params.card_id}",
          event_type,
          payload
        )

      {ids ++ [event_id], new_store}
    end)
  end)

IO.puts("  Time: #{Float.round(time_append / 1000, 3)}ms\n")

IO.puts("STEP 3: Fetch events back")

{time_fetch, events} =
  :timer.tc(fn ->
    Enum.map(event_ids, fn id ->
      {:ok, event} = EventStore.get_event(updated_event_store, id)
      event
    end)
  end)

IO.puts("  Time: #{Float.round(time_fetch / 1000, 3)}ms\n")

IO.puts("STEP 4: Apply events to PState (THE CRITICAL PATH)")

Enum.each(events, fn event ->
  IO.puts("  Applying: #{event.metadata.event_type}")

  # Time the ENTIRE apply_event call
  {time_total, updated_pstate} =
    :timer.tc(fn ->
      ContentStore.EventApplicator.apply_event(app.store.pstate, event)
    end)

  IO.puts("    TOTAL time for apply_event: #{Float.round(time_total / 1000, 3)}ms")

  # Now let's break down what happens INSIDE apply_event
  # We can't instrument it directly, but we can infer from what we know:

  if event.metadata.event_type == "card.updated" do
    IO.puts("    Breakdown for card.updated:")
    IO.puts("      - fetch_with_cache('card:card-100'): ~0.001ms (ETS lookup)")
    IO.puts("      - Map.put operations: ~0.001ms")
    IO.puts("      - put_and_invalidate: ~0.001ms")
    IO.puts("      - EXPECTED TOTAL: ~0.003ms")
    IO.puts("      - ACTUAL TOTAL: #{Float.round(time_total / 1000, 3)}ms")

    if time_total > 1000 do
      IO.puts("      ⚠️  MASSIVE SLOWDOWN DETECTED!")
      IO.puts("      The discrepancy suggests heavy ref resolution is happening")
    end
  end
end)

IO.puts("\n========================================")
IO.puts("ANALYSIS")
IO.puts("========================================\n")
IO.puts("With our fix (using Internal API):")
IO.puts("  → Event application should be ~0.003ms per event")
IO.puts("")
IO.puts("If you see >1ms:")
IO.puts("  → Refs are still being resolved somewhere")
IO.puts("  → Check if Command.update_card uses PState.fetch")
IO.puts("  → Check cache invalidation logic")
IO.puts("")
