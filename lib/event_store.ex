defmodule EventStore do
  @moduledoc """
  Public API for event store operations.

  EventStore provides a pluggable event sourcing system with support for
  multiple storage backends (adapters). Events are immutable and stored
  in append-only fashion, serving as the source of truth for PState
  materialization.

  ## Space Support

  Events are scoped to spaces (namespaces) for multi-tenancy isolation.
  Each space maintains its own independent sequence numbers while sharing
  the same underlying storage.

  ## Architecture

  The EventStore uses an adapter pattern to support different storage backends:

  - `EventStore.Adapters.ETS` - In-memory storage for development/testing
  - `EventStore.Adapters.SQLite` - Persistent storage for production

  ## Usage

      # Initialize with ETS adapter (development)
      {:ok, store} = EventStore.new(EventStore.Adapters.ETS, table_name: :my_events)

      # Initialize with SQLite adapter (production)
      {:ok, store} = EventStore.new(EventStore.Adapters.SQLite, database: "events.db")

      # Append an event to a space
      {:ok, event_id, space_sequence, store} = EventStore.append(
        store,
        1,  # space_id
        "base_card:123",
        "basecard.created",
        %{front: "Hello", back: "Hola"}
      )

      # Query events for an entity
      {:ok, events} = EventStore.get_events(store, "base_card:123")

      # Stream all events (memory efficient, yields individual events)
      stream = EventStore.stream_all_events(store, batch_size: 1000)
      stream |> Enum.take(10) |> Enum.each(&IO.inspect/1)

      # Stream events for a specific space
      stream = EventStore.stream_space_events(store, 1, from_sequence: 0)
      stream |> Enum.each(&IO.inspect/1)

  ## Event Structure

  All events share a common structure:

      %{
        metadata: %{
          event_id: 12345,                      # Global sequence
          space_id: 1,                          # Space identifier
          space_sequence: 42,                   # Per-space sequence
          entity_id: "base_card:uuid",          # Entity identifier
          event_type: "basecard.created",       # Event type (dot notation)
          timestamp: ~U[2025-01-17 12:00:00Z],  # When event occurred
          causation_id: 12340,                  # Optional: causing event
          correlation_id: "uuid"                # Optional: trace related events
        },
        payload: %{
          # Application-specific data
        }
      }

  ## References

  - ADR003: Event Store Architecture Decision
  - ADR004: PState Materialization from Events
  - ADR005: Space Support Architecture Decision
  - RMX005: Event Store Implementation Epic
  - RMX007: Space Support for Multi-Tenancy Epic
  """

  alias EventStore.Adapter

  defstruct [:adapter, :adapter_state]

  @type t :: %__MODULE__{
          adapter: module(),
          adapter_state: term()
        }

  # Re-export types from Adapter for convenience
  @type event :: Adapter.event()
  @type event_id :: Adapter.event_id()
  @type space_id :: Adapter.space_id()
  @type space_sequence :: Adapter.space_sequence()
  @type entity_id :: Adapter.entity_id()
  @type event_type :: Adapter.event_type()
  @type metadata :: Adapter.metadata()
  @type payload :: Adapter.payload()

  @doc """
  Create a new EventStore with the specified adapter.

  ## Examples

      {:ok, store} = EventStore.new(EventStore.Adapters.ETS)
      {:ok, store} = EventStore.new(EventStore.Adapters.SQLite, database: "events.db")
  """
  @spec new(module(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(adapter, opts \\ []) do
    case adapter.init(opts) do
      {:ok, adapter_state} ->
        {:ok, %__MODULE__{adapter: adapter, adapter_state: adapter_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Append a new event to the event store in a specific space.

  ## Parameters

  - `store` - EventStore instance
  - `space_id` - Space to append event to
  - `entity_id` - Entity identifier
  - `event_type` - Event type (dot notation recommended)
  - `payload` - Application-specific event data
  - `opts` - Additional options

  ## Options

  - `:causation_id` - ID of the event that caused this event
  - `:correlation_id` - ID for tracing related events (auto-generated if not provided)

  ## Examples

      {:ok, event_id, space_sequence, store} = EventStore.append(
        store,
        1,  # space_id
        "base_card:123",
        "basecard.created",
        %{front: "Hello", back: "Hola"}
      )

      {:ok, event_id, space_sequence, store} = EventStore.append(
        store,
        1,  # space_id
        "base_card:123",
        "basecard.updated",
        %{front: "Hi"},
        causation_id: previous_event_id,
        correlation_id: "batch-update-123"
      )
  """
  @spec append(t(), space_id(), entity_id(), event_type(), payload(), keyword()) ::
          {:ok, event_id(), space_sequence(), t()} | {:error, term()}
  def append(store, space_id, entity_id, event_type, payload, opts \\ []) do
    case store.adapter.append(store.adapter_state, space_id, entity_id, event_type, payload, opts) do
      {:ok, event_id, space_sequence, new_state} ->
        {:ok, event_id, space_sequence, %{store | adapter_state: new_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get all events for a specific entity.

  ## Options

  - `:from_sequence` - Only return events with event_id > this value (default: 0)
  - `:limit` - Maximum number of events to return (default: :infinity)

  ## Examples

      {:ok, events} = EventStore.get_events(store, "base_card:123")
      {:ok, events} = EventStore.get_events(store, "base_card:123", from_sequence: 100, limit: 50)
  """
  @spec get_events(t(), entity_id(), keyword()) :: {:ok, [event()]} | {:error, term()}
  def get_events(store, entity_id, opts \\ []) do
    store.adapter.get_events(store.adapter_state, entity_id, opts)
  end

  @doc """
  Get a single event by its event_id.

  ## Examples

      {:ok, event} = EventStore.get_event(store, 12345)
      {:error, :not_found} = EventStore.get_event(store, 99999)
  """
  @spec get_event(t(), event_id()) :: {:ok, event()} | {:error, :not_found} | {:error, term()}
  def get_event(store, event_id) do
    store.adapter.get_event(store.adapter_state, event_id)
  end

  @doc """
  Get all events from the event store.

  ## Options

  - `:from_sequence` - Only return events with event_id > this value (default: 0)
  - `:limit` - Maximum number of events to return (default: :infinity)

  ## Examples

      {:ok, events} = EventStore.get_all_events(store)
      {:ok, events} = EventStore.get_all_events(store, from_sequence: 1000, limit: 100)
  """
  @spec get_all_events(t(), keyword()) :: {:ok, [event()]} | {:error, term()}
  def get_all_events(store, opts \\ []) do
    store.adapter.get_all_events(store.adapter_state, opts)
  end

  @doc """
  Stream all events from the event store.

  Returns a lazy enumerable that yields individual events one at a time,
  fetching them in batches internally to avoid loading the entire event
  log into memory. Useful for processing large event logs (350k+ events).

  ## Options

  - `:from_sequence` - Only stream events with event_id > this value (default: 0)
  - `:batch_size` - Number of events to fetch per internal batch (default: 1000)

  ## Examples

      # Stream all events
      stream = EventStore.stream_all_events(store)
      Enum.take(stream, 100)

      # Stream with custom batch size for internal fetching
      stream = EventStore.stream_all_events(store, batch_size: 5000)
      Enum.each(stream, fn event -> IO.inspect(event.metadata.event_id) end)

      # Stream from a specific sequence
      stream = EventStore.stream_all_events(store, from_sequence: 10000)
      total = Enum.count(stream)
  """
  @spec stream_all_events(t(), keyword()) :: Enumerable.t()
  def stream_all_events(store, opts \\ []) do
    store.adapter.stream_all_events(store.adapter_state, opts)
  end

  @doc """
  Get the latest event sequence number (event_id).

  Returns the highest event_id in the store, or 0 if no events exist.

  ## Examples

      {:ok, 0} = EventStore.get_latest_sequence(empty_store)
      {:ok, 12345} = EventStore.get_latest_sequence(store_with_events)
  """
  @spec get_latest_sequence(t()) :: {:ok, event_id()} | {:ok, 0} | {:error, term()}
  def get_latest_sequence(store) do
    store.adapter.get_latest_sequence(store.adapter_state)
  end

  @doc """
  Stream all events for a specific space.

  Returns a lazy enumerable that yields individual events in the specified space,
  ordered by space_sequence (ascending).

  ## Options

  - `:from_sequence` - Only stream events with space_sequence > this value (default: 0)
  - `:batch_size` - Number of events to fetch per batch (default: 1000)

  ## Examples

      # Stream all events in space 1
      stream = EventStore.stream_space_events(store, 1)
      Enum.take(stream, 100)

      # Stream from a specific sequence in space 2
      stream = EventStore.stream_space_events(store, 2, from_sequence: 42)
      Enum.each(stream, fn event -> IO.inspect(event.metadata.space_sequence) end)
  """
  @spec stream_space_events(t(), space_id(), keyword()) :: Enumerable.t()
  def stream_space_events(store, space_id, opts \\ []) do
    store.adapter.stream_space_events(store.adapter_state, space_id, opts)
  end

  @doc """
  Get the latest space sequence number for a specific space.

  Returns the highest space_sequence for the given space_id, or 0 if no events
  exist in that space.

  ## Examples

      {:ok, 0} = EventStore.get_space_latest_sequence(store, 1)
      {:ok, 42} = EventStore.get_space_latest_sequence(store, 1)
  """
  @spec get_space_latest_sequence(t(), space_id()) ::
          {:ok, space_sequence()} | {:ok, 0} | {:error, term()}
  def get_space_latest_sequence(store, space_id) do
    store.adapter.get_space_latest_sequence(store.adapter_state, space_id)
  end
end
