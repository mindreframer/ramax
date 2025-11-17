defmodule FlashcardApp do
  @moduledoc """
  Simple flashcard application demonstrating event sourcing with ContentStore.

  FlashcardApp is a complete example application showcasing how to use ContentStore
  for building event-sourced applications. It demonstrates:

  - Creating decks and cards
  - Updating card content
  - Adding translations to cards
  - Querying decks and cards
  - Rebuilding PState from events

  ## Features

  - **Deck Management**: Create and manage flashcard decks
  - **Card CRUD**: Create, read, and update flashcards
  - **Translations**: Add multi-language translations to cards
  - **Event Sourcing**: All changes tracked as immutable events
  - **Rebuild Support**: Reconstruct state from event history

  ## Architecture

  FlashcardApp is a thin wrapper around ContentStore that provides a domain-specific
  API for flashcard operations. All state changes go through commands that generate
  events, which are then applied to PState.

  ## Usage

      # Create a new app
      app = FlashcardApp.new()

      # Create a deck
      {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")

      # Add a card
      {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101",
        "Hello", "Hola")

      # Add a translation
      {:ok, app} = FlashcardApp.add_translation(app, "card-1", :front, "fr", "Bonjour")

      # Query the deck
      {:ok, deck} = FlashcardApp.get_deck(app, "spanish-101")

      # List all cards in deck
      {:ok, cards} = FlashcardApp.list_deck_cards(app, "spanish-101")

      # Update a card
      {:ok, app} = FlashcardApp.update_card(app, "card-1", "Hello!", "¡Hola!")

      # Rebuild PState from events
      app = FlashcardApp.rebuild(app)

  ## References

  - ADR004: PState Materialization from Events
  - RMX006: Event Application to PState Epic
  """

  alias FlashcardCommand, as: Command

  defstruct [:store]

  @type t :: %__MODULE__{
          store: ContentStore.t()
        }

  @doc """
  Create a new FlashcardApp instance.

  Initializes a ContentStore with the specified options.

  ## Options

  All options are passed through to `ContentStore.new/1`:

  - `:event_adapter` - EventStore adapter module (default: `EventStore.Adapters.ETS`)
  - `:event_opts` - Options for EventStore adapter (default: `[]`)
  - `:pstate_adapter` - PState adapter module (default: `PState.Adapters.ETS`)
  - `:pstate_opts` - Options for PState adapter (default: `[]`)
  - `:root_key` - Root key for PState (default: `"content:root"`)
  - `:schema` - PState schema (optional)

  ## Examples

      # In-memory app for development/testing
      app = FlashcardApp.new()

      # Custom configuration
      app = FlashcardApp.new(
        event_adapter: EventStore.Adapters.SQLite,
        event_opts: [database: "flashcards.db"],
        pstate_adapter: PState.Adapters.ETS
      )

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    # Add flashcard-specific event applicator to opts
    opts = Keyword.put_new(opts, :event_applicator, FlashcardEventApplicator)

    store = ContentStore.new(opts)
    %__MODULE__{store: store}
  end

  # Public API - Write Operations

  @doc """
  Create a new flashcard deck.

  ## Parameters

  - `app` - Current FlashcardApp instance
  - `deck_id` - Unique identifier for the deck
  - `name` - Human-readable name for the deck

  ## Returns

  - `{:ok, updated_app}` - Deck created successfully
  - `{:error, {:deck_already_exists, deck_id}}` - Deck already exists

  ## Examples

      {:ok, app} = FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")
      {:ok, app} = FlashcardApp.create_deck(app, "french-101", "French Basics")

      # Error: deck already exists
      {:error, {:deck_already_exists, "spanish-101"}} =
        FlashcardApp.create_deck(app, "spanish-101", "Spanish Basics")

  """
  @spec create_deck(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def create_deck(app, deck_id, name) do
    params = %{deck_id: deck_id, name: name}

    case ContentStore.execute(app.store, &Command.create_deck/2, params) do
      {:ok, _event_ids, updated_store} ->
        {:ok, %{app | store: updated_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Create a new flashcard in a deck.

  ## Parameters

  - `app` - Current FlashcardApp instance
  - `card_id` - Unique identifier for the card
  - `deck_id` - ID of the deck to add the card to
  - `front` - Front side content (e.g., question or English word)
  - `back` - Back side content (e.g., answer or Spanish translation)

  ## Returns

  - `{:ok, updated_app}` - Card created successfully
  - `{:error, {:deck_not_found, deck_id}}` - Deck doesn't exist
  - `{:error, {:card_already_exists, card_id}}` - Card already exists

  ## Examples

      {:ok, app} = FlashcardApp.create_card(app, "card-1", "spanish-101",
        "Hello", "Hola")

      {:ok, app} = FlashcardApp.create_card(app, "card-2", "spanish-101",
        "Goodbye", "Adiós")

      # Error: deck not found
      {:error, {:deck_not_found, "french-101"}} =
        FlashcardApp.create_card(app, "card-3", "french-101", "Hello", "Bonjour")

  """
  @spec create_card(t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, term()}
  def create_card(app, card_id, deck_id, front, back) do
    params = %{
      card_id: card_id,
      deck_id: deck_id,
      front: front,
      back: back
    }

    case ContentStore.execute(app.store, &Command.create_card/2, params) do
      {:ok, _event_ids, updated_store} ->
        {:ok, %{app | store: updated_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Update the content of an existing flashcard.

  Updates both the front and back of a card. If the change is significant
  (based on content length), existing translations will be marked as invalidated.

  ## Parameters

  - `app` - Current FlashcardApp instance
  - `card_id` - ID of the card to update
  - `front` - New front side content
  - `back` - New back side content

  ## Returns

  - `{:ok, updated_app}` - Card updated successfully
  - `{:error, {:card_not_found, card_id}}` - Card doesn't exist
  - `{:error, :no_changes}` - Content unchanged

  ## Examples

      {:ok, app} = FlashcardApp.update_card(app, "card-1",
        "Hello!", "¡Hola!")

      # Error: no changes
      {:error, :no_changes} =
        FlashcardApp.update_card(app, "card-1", "Hello!", "¡Hola!")

  """
  @spec update_card(t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, term()}
  def update_card(app, card_id, front, back) do
    params = %{card_id: card_id, front: front, back: back}

    case ContentStore.execute(app.store, &Command.update_card/2, params) do
      {:ok, _event_ids, updated_store} ->
        {:ok, %{app | store: updated_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Add a translation to a card field.

  Translations are stored per field (`:front` or `:back`) and language.

  ## Parameters

  - `app` - Current FlashcardApp instance
  - `card_id` - ID of the card to add translation to
  - `field` - Field to translate (`:front` or `:back`)
  - `language` - Language code (e.g., `"en"`, `"fr"`, `"es"`)
  - `translation` - Translated text

  ## Returns

  - `{:ok, updated_app}` - Translation added successfully
  - `{:error, {:card_not_found, card_id}}` - Card doesn't exist
  - `{:error, :translation_exists}` - Translation already exists

  ## Examples

      {:ok, app} = FlashcardApp.add_translation(app, "card-1", :front, "fr", "Bonjour")
      {:ok, app} = FlashcardApp.add_translation(app, "card-1", :back, "en", "Hello")

      # Error: translation exists
      {:error, :translation_exists} =
        FlashcardApp.add_translation(app, "card-1", :front, "fr", "Salut")

  """
  @spec add_translation(t(), String.t(), atom(), String.t(), String.t()) ::
          {:ok, t()} | {:error, term()}
  def add_translation(app, card_id, field, language, translation) do
    params = %{
      card_id: card_id,
      field: field,
      language: language,
      translation: translation
    }

    case ContentStore.execute(app.store, &Command.add_translation/2, params) do
      {:ok, _event_ids, updated_store} ->
        {:ok, %{app | store: updated_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Public API - Query Operations

  @doc """
  Get a deck by ID.

  ## Parameters

  - `app` - Current FlashcardApp instance
  - `deck_id` - ID of the deck to retrieve

  ## Returns

  - `{:ok, deck}` - Deck data map
  - `:error` - Deck not found

  ## Examples

      {:ok, deck} = FlashcardApp.get_deck(app, "spanish-101")
      # => {:ok, %{id: "spanish-101", name: "Spanish Basics", cards: %{...}}}

      :error = FlashcardApp.get_deck(app, "nonexistent")

  """
  @spec get_deck(t(), String.t()) :: {:ok, map()} | :error
  def get_deck(app, deck_id) do
    PState.fetch(app.store.pstate, "deck:#{deck_id}")
  end

  @doc """
  Get a card by ID.

  ## Parameters

  - `app` - Current FlashcardApp instance
  - `card_id` - ID of the card to retrieve

  ## Returns

  - `{:ok, card}` - Card data map
  - `:error` - Card not found

  ## Examples

      {:ok, card} = FlashcardApp.get_card(app, "card-1")
      # => {:ok, %{id: "card-1", front: "Hello", back: "Hola", ...}}

      :error = FlashcardApp.get_card(app, "nonexistent")

  """
  @spec get_card(t(), String.t()) :: {:ok, map()} | :error
  def get_card(app, card_id) do
    # Use depth: 0 to get card with deck as a Ref (not resolved)
    # This avoids loading the deck with all 1500+ card refs
    # If you need deck info, fetch it separately with get_deck/2
    PState.fetch(app.store.pstate, "card:#{card_id}")
  end

  @doc """
  List all cards in a deck.

  ## Parameters

  - `app` - Current FlashcardApp instance
  - `deck_id` - ID of the deck

  ## Returns

  - `{:ok, cards}` - List of card data maps
  - `{:error, :deck_not_found}` - Deck not found

  ## Examples

      {:ok, cards} = FlashcardApp.list_deck_cards(app, "spanish-101")
      # => {:ok, [%{id: "card-1", ...}, %{id: "card-2", ...}]}

      {:error, :deck_not_found} = FlashcardApp.list_deck_cards(app, "nonexistent")

  """
  @spec list_deck_cards(t(), String.t()) :: {:ok, [map()]} | {:error, :deck_not_found}
  def list_deck_cards(app, deck_id) do
    case get_deck(app, deck_id) do
      {:ok, deck} ->
        cards =
          deck.cards
          |> Map.keys()
          |> Enum.map(fn card_id ->
            # Use depth: 0 for listing - we don't need deck info in each card
            # since we already know which deck we're querying
            {:ok, card} = PState.fetch(app.store.pstate, "card:#{card_id}")
            card
          end)

        {:ok, cards}

      :error ->
        {:error, :deck_not_found}
    end
  end

  @doc """
  Get the total number of events in the event store.

  Useful for monitoring, debugging, and testing.

  ## Parameters

  - `app` - Current FlashcardApp instance

  ## Returns

  - Non-negative integer representing the number of events

  ## Examples

      count = FlashcardApp.get_event_count(app)
      # => 5

  """
  @spec get_event_count(t()) :: non_neg_integer()
  def get_event_count(app) do
    {:ok, seq} = EventStore.get_latest_sequence(app.store.event_store)
    seq
  end

  @doc """
  Rebuild PState from all events in the event store.

  Creates a fresh PState and replays all events. Useful for:

  - Verifying event sourcing correctness
  - Recovering from PState corruption
  - Testing event applicators
  - Schema migrations

  ## Parameters

  - `app` - Current FlashcardApp instance

  ## Returns

  - Updated FlashcardApp with rebuilt PState

  ## Examples

      # Rebuild and verify data integrity
      {:ok, deck_before} = FlashcardApp.get_deck(app, "spanish-101")
      app = FlashcardApp.rebuild(app)
      {:ok, deck_after} = FlashcardApp.get_deck(app, "spanish-101")
      assert deck_before == deck_after

  """
  @spec rebuild(t()) :: t()
  def rebuild(app) do
    updated_store = ContentStore.rebuild_pstate(app.store)
    %{app | store: updated_store}
  end
end
