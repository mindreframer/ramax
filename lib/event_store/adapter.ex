defmodule EventStore.Adapter do
  @moduledoc """
  Behaviour for pluggable event store backends.

  This module defines the adapter interface for event store implementations.
  Adapters can be backed by different storage mechanisms (ETS, SQLite, etc.)
  while providing a consistent API for event sourcing operations.

  ## Space Support

  Events are scoped to spaces (namespaces) for multi-tenancy isolation.
  Each space has:
  - `space_id` - Unique integer identifier used in data storage
  - Per-space sequence numbers independent of other spaces
  - Complete isolation from events in other spaces

  ## Event Structure

  Events consist of metadata and payload:

      %{
        metadata: %{
          event_id: 12345,                      # Global sequence
          space_id: 1,                          # Space identifier
          space_sequence: 42,                   # Per-space sequence
          entity_id: "base_card:uuid",
          event_type: "basecard.created",
          timestamp: ~U[2025-01-17 12:00:00Z],
          causation_id: 12340,
          correlation_id: "uuid"
        },
        payload: %{
          # Application-specific data
        }
      }

  ## References

  - ADR003: Event Store Architecture Decision
  - ADR004: PState Materialization from Events
  - ADR005: Space Support Architecture Decision
  """

  @type event_id :: pos_integer()
  @type space_id :: pos_integer()
  @type space_sequence :: pos_integer()
  @type entity_id :: String.t()
  @type event_type :: String.t()
  @type payload :: map()
  @type state :: term()
  @type opts :: keyword()

  @type metadata :: %{
          event_id: event_id(),
          space_id: space_id(),
          space_sequence: space_sequence(),
          entity_id: entity_id(),
          event_type: event_type(),
          timestamp: DateTime.t(),
          causation_id: event_id() | nil,
          correlation_id: String.t() | nil
        }

  @type event :: %{
          metadata: metadata(),
          payload: payload()
        }

  @doc """
  Initialize the adapter with the given options.

  Returns `{:ok, state}` on success or `{:error, reason}` on failure.

  ## Examples

      {:ok, state} = MyAdapter.init(database: "events.db")
  """
  @callback init(opts) :: {:ok, state} | {:error, term()}

  @doc """
  Append a new event to a specific space in the event store.

  The adapter is responsible for:
  - Generating a unique, sequential global event_id
  - Generating a per-space space_sequence
  - Creating event metadata (timestamp, correlation_id if not provided)
  - Storing the event immutably with space_id
  - Updating any indexes for efficient querying

  ## Parameters

  - `state` - Adapter state
  - `space_id` - The space to append the event to
  - `entity_id` - Entity identifier
  - `event_type` - Event type (dot notation recommended)
  - `payload` - Application-specific event data
  - `opts` - Additional options

  ## Options

  - `:causation_id` - ID of the event that caused this event
  - `:correlation_id` - ID for tracing related events (auto-generated if not provided)

  Returns `{:ok, event_id, space_sequence, new_state}` on success or `{:error, reason}` on failure.
  """
  @callback append(state, space_id, entity_id, event_type, payload, opts) ::
              {:ok, event_id, space_sequence, state} | {:error, term()}

  @doc """
  Get all events for a specific entity.

  ## Options

  - `:from_sequence` - Only return events with event_id > this value (default: 0)
  - `:limit` - Maximum number of events to return (default: :infinity)

  Returns `{:ok, events}` where events are ordered by event_id (ascending).
  """
  @callback get_events(state, entity_id, opts) ::
              {:ok, [event()]} | {:error, term()}

  @doc """
  Get a single event by its event_id.

  Returns `{:ok, event}` if found, `{:error, :not_found}` if not found,
  or `{:error, reason}` on other errors.
  """
  @callback get_event(state, event_id) ::
              {:ok, event()} | {:error, :not_found} | {:error, term()}

  @doc """
  Get all events from the event store.

  ## Options

  - `:from_sequence` - Only return events with event_id > this value (default: 0)
  - `:limit` - Maximum number of events to return (default: :infinity)

  Returns `{:ok, events}` where events are ordered by event_id (ascending).
  """
  @callback get_all_events(state, opts) ::
              {:ok, [event()]} | {:error, term()}

  @doc """
  Stream all events from the event store.

  This should return a lazy enumerable that yields events in batches
  to avoid loading the entire event log into memory.

  ## Options

  - `:from_sequence` - Only stream events with event_id > this value (default: 0)
  - `:batch_size` - Number of events to fetch per batch (default: 1000)

  Returns an `Enumerable.t()` that yields events.
  """
  @callback stream_all_events(state, opts) :: Enumerable.t()

  @doc """
  Get the latest event sequence number (event_id).

  Returns `{:ok, event_id}` if events exist, `{:ok, 0}` if no events exist,
  or `{:error, reason}` on error.
  """
  @callback get_latest_sequence(state) ::
              {:ok, event_id()} | {:ok, 0} | {:error, term()}

  @doc """
  Stream all events for a specific space.

  Returns a lazy enumerable that yields events in the specified space,
  ordered by space_sequence (ascending).

  ## Options

  - `:from_sequence` - Only stream events with space_sequence > this value (default: 0)
  - `:batch_size` - Number of events to fetch per batch (default: 1000)

  Returns an `Enumerable.t()` that yields events.
  """
  @callback stream_space_events(state, space_id, opts) :: Enumerable.t()

  @doc """
  Get the latest space sequence number for a specific space.

  Returns the highest space_sequence for the given space_id, or 0 if no events
  exist in that space.

  ## Examples

      {:ok, 0} = adapter.get_space_latest_sequence(state, 1)
      {:ok, 42} = adapter.get_space_latest_sequence(state, 1)
  """
  @callback get_space_latest_sequence(state, space_id) ::
              {:ok, space_sequence()} | {:ok, 0} | {:error, term()}

  @doc """
  Close the adapter and release any resources (database connections, file handles, etc.).

  This is optional for in-memory adapters but critical for adapters that hold persistent
  resources like database connections.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Examples

      :ok = MyAdapter.close(state)
  """
  @callback close(state) :: :ok | {:error, term()}
end
