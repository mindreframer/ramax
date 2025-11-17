defmodule FlashcardCommand do
  @moduledoc """
  Flashcard-specific commands that validate current state and generate events.

  Commands are pure functions that take the current PState and parameters,
  validate the operation is allowed, and return event specifications that
  should be appended to the event store.

  ## Design Principles

  1. **Pure Functions**: No side effects, same inputs → same outputs
  2. **Validation First**: Check all preconditions before generating events
  3. **Event Generation**: Return `{:ok, event_specs}` or `{:error, reason}`
  4. **Event Specs**: `{event_type :: String.t(), payload :: map()}`

  ## Examples

      # Create a deck
      iex> pstate = PState.new("content:root")
      iex> params = %{deck_id: "spanish-101", name: "Spanish Basics"}
      iex> Command.create_deck(pstate, params)
      {:ok, [{"deck.created", %{deck_id: "spanish-101", name: "Spanish Basics"}}]}

      # Create a card (validates deck exists)
      iex> pstate = PState.new("content:root")
      iex> params = %{card_id: "c1", deck_id: "d1", front: "Hello", back: "Hola"}
      iex> Command.create_card(pstate, params)
      {:error, {:deck_not_found, "d1"}}

  """

  @type params :: map()
  @type event_spec :: {event_type :: String.t(), payload :: map()}

  # Deck Commands

  @doc """
  Create a new deck.

  ## Parameters
  - `pstate`: Current PState
  - `params`: Map with `:deck_id` and `:name`

  ## Returns
  - `{:ok, [event_spec]}` - Deck creation event
  - `{:error, {:deck_already_exists, deck_id}}` - Deck exists
  """
  def create_deck(pstate, params) do
    case validate_deck_not_exists(pstate, params.deck_id) do
      :ok ->
        event = %{
          deck_id: params.deck_id,
          name: params.name
        }

        {:ok, [{"deck.created", event}]}

      error ->
        error
    end
  end

  # Card Commands

  @doc """
  Create a new card in a deck.

  ## Parameters
  - `pstate`: Current PState
  - `params`: Map with `:card_id`, `:deck_id`, `:front`, `:back`

  ## Returns
  - `{:ok, [event_spec]}` - Card creation event
  - `{:error, {:deck_not_found, deck_id}}` - Deck doesn't exist
  - `{:error, {:card_already_exists, card_id}}` - Card already exists
  """
  def create_card(pstate, params) do
    with :ok <- validate_deck_exists(pstate, params.deck_id),
         :ok <- validate_card_not_exists(pstate, params.card_id) do
      event = %{
        card_id: params.card_id,
        deck_id: params.deck_id,
        front: params.front,
        back: params.back
      }

      {:ok, [{"card.created", event}]}
    end
  end

  @doc """
  Update an existing card's content.

  Validates that:
  - Card exists
  - Content has actually changed

  If the change is significant (based on length heuristic), also generates
  a translation invalidation event.

  ## Parameters
  - `pstate`: Current PState
  - `params`: Map with `:card_id`, `:front`, `:back`

  ## Returns
  - `{:ok, [event_spec, ...]}` - Update event(s)
  - `{:error, {:card_not_found, card_id}}` - Card doesn't exist
  - `{:error, :no_changes}` - Content unchanged
  """
  def update_card(pstate, params) do
    with {:ok, card} <- get_card(pstate, params.card_id),
         :ok <- validate_content_changed(card, params) do
      events = [
        {"card.updated",
         %{
           card_id: params.card_id,
           front: params.front,
           back: params.back
         }}
      ]

      # Generate invalidation events if content significantly changed
      events =
        if significant_change?(card, params) do
          events ++ [{"card.translations.invalidated", %{card_id: params.card_id}}]
        else
          events
        end

      {:ok, events}
    end
  end

  @doc """
  Add a translation to a card field.

  ## Parameters
  - `pstate`: Current PState
  - `params`: Map with `:card_id`, `:field`, `:language`, `:translation`

  ## Returns
  - `{:ok, [event_spec]}` - Translation added event
  - `{:error, {:card_not_found, card_id}}` - Card doesn't exist
  - `{:error, :translation_exists}` - Translation already exists
  """
  def add_translation(pstate, params) do
    with {:ok, card} <- get_card(pstate, params.card_id),
         :ok <- validate_translation_new(card, params) do
      event = %{
        card_id: params.card_id,
        field: params.field,
        language: params.language,
        translation: params.translation
      }

      {:ok, [{"card.translation.added", event}]}
    end
  end

  # Validation Helpers

  defp validate_deck_exists(pstate, deck_id) do
    case PState.fetch(pstate, "deck:#{deck_id}") do
      {:ok, _deck} -> :ok
      :error -> {:error, {:deck_not_found, deck_id}}
    end
  end

  defp validate_deck_not_exists(pstate, deck_id) do
    case PState.fetch(pstate, "deck:#{deck_id}") do
      {:ok, _} -> {:error, {:deck_already_exists, deck_id}}
      :error -> :ok
    end
  end

  defp validate_card_not_exists(pstate, card_id) do
    case PState.fetch(pstate, "card:#{card_id}") do
      {:ok, _} -> {:error, {:card_already_exists, card_id}}
      :error -> :ok
    end
  end

  defp get_card(pstate, card_id) do
    case PState.fetch(pstate, "card:#{card_id}") do
      {:ok, card} -> {:ok, card}
      :error -> {:error, {:card_not_found, card_id}}
    end
  end

  defp validate_content_changed(card, params) do
    if card.front == params.front && card.back == params.back do
      {:error, :no_changes}
    else
      :ok
    end
  end

  defp validate_translation_new(card, params) do
    existing = get_in(card, [:translations, params.field, params.language])
    if existing, do: {:error, :translation_exists}, else: :ok
  end

  defp significant_change?(card, params) do
    # Simple heuristic: if front or back changes by length, it's significant
    front_changed = String.length(params.front) != String.length(card.front)
    back_changed = String.length(params.back) != String.length(card.back)
    front_changed || back_changed
  end
end
