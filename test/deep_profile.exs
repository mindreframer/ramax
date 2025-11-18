# Deep instrumentation to find EXACT bottleneck
# Run with: mix run test/deep_profile.exs

defmodule DeepProfiler do
  def instrument_pstate_fetch() do
    # We'll manually count how many times fetch is called and how deep
    Process.put(:pstate_fetch_count, 0)
    Process.put(:pstate_fetch_depth, 0)
    Process.put(:pstate_max_depth, 0)
  end

  def reset_counters() do
    Process.put(:pstate_fetch_count, 0)
    Process.put(:pstate_fetch_depth, 0)
    Process.put(:pstate_max_depth, 0)
  end

  def get_stats() do
    %{
      fetch_count: Process.get(:pstate_fetch_count, 0),
      max_depth: Process.get(:pstate_max_depth, 0)
    }
  end

  def trace_update(app, card_id) do
    reset_counters()

    # Trace EXACTLY what happens during update
    IO.puts("\n=== TRACING UPDATE FOR card-#{card_id} ===\n")

    # Manually instrument the update path
    params = %{card_id: "card-#{card_id}", front: "New", back: "New"}

    IO.puts("1. Calling Command.update_card...")

    {time_command, {:ok, event_specs}} =
      :timer.tc(fn ->
        Command.update_card(app.store.pstate, params)
      end)

    IO.puts("   Time: #{Float.round(time_command / 1000, 3)}ms")
    IO.puts("   Events generated: #{length(event_specs)}")

    IO.puts("\n2. Appending events to store...")

    {time_append, {event_ids, updated_event_store}} =
      :timer.tc(fn ->
        ContentStore.append_events(app.store.event_store, event_specs, params)
      end)

    IO.puts("   Time: #{Float.round(time_append / 1000, 3)}ms")

    IO.puts("\n3. Fetching events back...")

    {time_fetch, events} =
      :timer.tc(fn ->
        ContentStore.fetch_events(updated_event_store, event_ids)
      end)

    IO.puts("   Time: #{Float.round(time_fetch / 1000, 3)}ms")

    IO.puts("\n4. Applying events to PState...")
    IO.puts("   Events to apply: #{length(events)}")

    Enum.each(events, fn event ->
      IO.puts("   - Applying #{event.metadata.event_type}...")

      {time_apply, _} =
        :timer.tc(fn ->
          EventApplicator.apply_event(app.store.pstate, event)
        end)

      IO.puts("     Time: #{Float.round(time_apply / 1000, 3)}ms")
    end)

    IO.puts("\n=== TRACE COMPLETE ===\n")
  end
end

IO.puts("\n========================================")
IO.puts("DEEP PROFILING - EXACT BOTTLENECK LOCATION")
IO.puts("========================================\n")

# Setup with different sizes to see scaling
Enum.each([10, 50, 100, 200], fn card_count ->
  IO.puts("Testing with #{card_count} cards...")

  app = FlashcardApp.new(space_name: "profile_test")
  {:ok, app} = FlashcardApp.create_deck(app, "deck-1", "Test")

  app =
    Enum.reduce(1..card_count, app, fn i, acc ->
      {:ok, updated} = FlashcardApp.create_card(acc, "card-#{i}", "deck-1", "F#{i}", "B#{i}")
      updated
    end)

  # Now trace a single update
  DeepProfiler.trace_update(app, div(card_count, 2))

  IO.puts("\n" <> String.duplicate("=", 60) <> "\n")
end)

IO.puts("\n========================================")
IO.puts("ANALYSIS: Where is the time going?")
IO.puts("========================================\n")
IO.puts("If Command.update_card takes significant time:")
IO.puts("  → Problem is in PState.fetch (ref resolution in command)")
IO.puts("")
IO.puts("If Applying events takes significant time:")
IO.puts("  → Problem is in EventApplicator (ref resolution in applicators)")
IO.puts("")
IO.puts("If neither takes much time:")
IO.puts("  → Problem is elsewhere (event store, cache invalidation, etc.)")
IO.puts("")
