defmodule FlashcardEntityId do
  @moduledoc """
  Entity ID extraction for flashcard application events.

  This module provides the entity_id_extractor function needed by ContentStore
  to determine which entity each event belongs to. This keeps the flashcard
  domain logic separate from the generic ContentStore.

  ## Usage

      store = ContentStore.new(
        entity_id_extractor: &FlashcardEntityId.extract/1,
        event_applicator: FlashcardEventApplicator
      )

  ## Entity ID Patterns

  - Deck events (`deck_id` present) → `"deck:\#{deck_id}"`
  - Card events (`card_id` present) → `"card:\#{card_id}"`
  - Other events → `"content:root"` (default root entity)
  """

  @doc """
  Extract entity ID from event payload.

  ## Examples

      iex> FlashcardEntityId.extract(%{deck_id: "spanish-101", name: "Spanish"})
      "deck:spanish-101"

      iex> FlashcardEntityId.extract(%{card_id: "c1", front: "Hello"})
      "card:c1"

      iex> FlashcardEntityId.extract(%{some_other_field: "value"})
      "content:root"
  """
  @spec extract(map()) :: String.t()
  def extract(%{card_id: id}), do: "card:#{id}"
  def extract(%{deck_id: id}), do: "deck:#{id}"
  def extract(_), do: "content:root"
end
