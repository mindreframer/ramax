defmodule FlashcardEventApplicator do
  @moduledoc """
  Flashcard-specific event applicator - applies flashcard domain events to PState.

  EventApplicator is the heart of the event sourcing system. It transforms
  immutable events from the EventStore into PState updates, enabling:
  - Complete PState rebuild from events
  - Incremental updates
  - Schema evolution and backward compatibility

  ## Key Principles

  1. **Always create data in CURRENT schema shape** - Even if events are old,
     the resulting PState data must match current schema
  2. **Never modify event payload** - Events are immutable source of truth
  3. **Unknown events are ignored** - Enables forward compatibility
  4. **Must remain backward compatible** - Old events must still apply
  5. **Pure functions** - Same event + same PState = same result

  ## Performance Note

  Event applicators safely use standard `put_in/update_in` functions because
  `pstate[key]` now defaults to depth: 0 (no automatic reference resolution).
  This prevents O(n²) performance degradation with circular references.

  ## Schema Evolution Example

      # Old event from v1 (no translations field)
      event = %{
        metadata: %{event_type: "card.created", ...},
        payload: %{card_id: "c1", front: "Hello", back: "Hola"}
      }

      # Apply with current schema (v2) - adds translations field
      pstate = apply_event(pstate, event)

      # Result has current schema shape
      pstate["card:c1"] = %{
        id: "c1",
        front: "Hello",
        back: "Hola",
        translations: %{},  # New field in v2!
        created_at: ...
      }

  ## References

  - ADR004: PState Materialization from Events
  - RMX006: Event Application to PState Epic
  """

  alias PState.Ref

  @doc """
  Apply a single event to PState.

  Events are dispatched based on `event.metadata.event_type`. Unknown event
  types are silently ignored for forward compatibility.

  ## Examples

      iex> event = %{
      ...>   metadata: %{event_type: "card.created", timestamp: ~U[2025-01-17 12:00:00Z]},
      ...>   payload: %{card_id: "c1", deck_id: "d1", front: "Hello", back: "Hola"}
      ...> }
      iex> pstate = PState.new("content:root")
      iex> pstate = put_in(pstate["deck:d1"], %{id: "d1", cards: %{}})
      iex> pstate = apply_event(pstate, event)
      iex> pstate["card:c1"].front
      "Hello"

  """
  @spec apply_event(PState.t(), EventStore.event()) :: PState.t()
  def apply_event(pstate, event) do
    case event.metadata.event_type do
      "deck.created" -> apply_deck_created(pstate, event)
      "card.created" -> apply_card_created(pstate, event)
      "card.updated" -> apply_card_updated(pstate, event)
      "card.translation.added" -> apply_translation_added(pstate, event)
      "card.translations.invalidated" -> apply_translations_invalidated(pstate, event)
      # Unknown events ignored for forward compatibility
      _ -> pstate
    end
  end

  @doc """
  Apply multiple events to PState in order.

  This is the primary function used during PState rebuild and catchup operations.
  Events are applied sequentially, with each event operating on the result of
  the previous event application.

  ## Examples

      iex> events = [
      ...>   %{metadata: %{event_type: "deck.created", ...}, payload: %{deck_id: "d1", ...}},
      ...>   %{metadata: %{event_type: "card.created", ...}, payload: %{card_id: "c1", ...}}
      ...> ]
      iex> pstate = PState.new("content:root")
      iex> pstate = apply_events(pstate, events)
      iex> {:ok, _deck} = PState.fetch(pstate, "deck:d1")
      iex> {:ok, _card} = PState.fetch(pstate, "card:c1")

  """
  @spec apply_events(PState.t(), [EventStore.event()]) :: PState.t()
  def apply_events(pstate, events) do
    Enum.reduce(events, pstate, &apply_event(&2, &1))
  end

  # Event Applicators

  defp apply_deck_created(pstate, event) do
    p = event.payload
    deck_key = "deck:#{p.deck_id}"

    deck_data = %{
      id: p.deck_id,
      name: p.name,
      cards: %{},
      created_at: DateTime.to_unix(event.metadata.timestamp)
    }

    # Safe to use put_in now that pstate[key] doesn't auto-resolve (depth: 0)
    put_in(pstate[deck_key], deck_data)
  end

  defp apply_card_created(pstate, event) do
    p = event.payload
    card_key = "card:#{p.card_id}"
    deck_key = "deck:#{p.deck_id}"

    # Create card with CURRENT schema shape
    card_data = %{
      id: p.card_id,
      front: p.front,
      back: p.back,
      deck: Ref.new(:deck, p.deck_id),
      translations: %{},
      created_at: DateTime.to_unix(event.metadata.timestamp)
    }

    # Safe to use put_in/update_in now that pstate[key] doesn't auto-resolve
    pstate = put_in(pstate[card_key], card_data)

    # Add card to deck's cards map
    pstate =
      update_in(pstate[deck_key], fn deck ->
        update_in(deck.cards, fn cards ->
          Map.put(cards, p.card_id, Ref.new(:card, p.card_id))
        end)
      end)

    pstate
  end

  defp apply_card_updated(pstate, event) do
    p = event.payload
    card_key = "card:#{p.card_id}"

    # Safe to use update_in now that pstate[key] doesn't auto-resolve
    update_in(pstate[card_key], fn card ->
      card
      |> Map.put(:front, p.front)
      |> Map.put(:back, p.back)
      |> Map.put(:updated_at, DateTime.to_unix(event.metadata.timestamp))
    end)
  end

  defp apply_translation_added(pstate, event) do
    p = event.payload
    card_key = "card:#{p.card_id}"

    # Safe to use update_in now that pstate[key] doesn't auto-resolve (depth: 0)
    update_in(pstate[card_key], fn card ->
      translations_for_field = get_in(card, [:translations, p.field]) || %{}

      updated_translations =
        Map.put(translations_for_field, p.language, %{
          text: p.translation,
          added_at: DateTime.to_unix(event.metadata.timestamp)
        })

      put_in(card, [:translations, p.field], updated_translations)
    end)
  end

  defp apply_translations_invalidated(pstate, event) do
    p = event.payload
    card_key = "card:#{p.card_id}"

    # Safe to use update_in now that pstate[key] doesn't auto-resolve (depth: 0)
    update_in(pstate[card_key], fn card ->
      put_in(card, [:translations, :_invalidated], true)
    end)
  end
end
