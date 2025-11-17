defmodule EventStore.Adapter do
  @moduledoc """
  Behaviour for pluggable event store backends.

  This module defines the adapter interface for event store implementations.
  Adapters can be backed by different storage mechanisms (ETS, SQLite, etc.)
  while providing a consistent API for event sourcing operations.

  ## Event Structure

  Events consist of metadata and payload:

      %{
        metadata: %{
          event_id: 12345,
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
  """

  @type event_id :: pos_integer()
  @type entity_id :: String.t()
  @type event_type :: String.t()
  @type payload :: map()
  @type state :: term()
  @type opts :: keyword()

  @type metadata :: %{
          event_id: event_id(),
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
  Append a new event to the event store.

  The adapter is responsible for:
  - Generating a unique, sequential event_id
  - Creating event metadata (timestamp, correlation_id if not provided)
  - Storing the event immutably
  - Updating any indexes for efficient querying

  ## Options

  - `:causation_id` - ID of the event that caused this event
  - `:correlation_id` - ID for tracing related events (auto-generated if not provided)

  Returns `{:ok, event_id, new_state}` on success or `{:error, reason}` on failure.
  """
  @callback append(state, entity_id, event_type, payload, opts) ::
              {:ok, event_id, state} | {:error, term()}

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
end
