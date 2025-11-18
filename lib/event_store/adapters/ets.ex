defmodule EventStore.Adapters.ETS do
  @moduledoc """
  ETS-based event store adapter for development and testing.

  This adapter uses Erlang's ETS (Erlang Term Storage) for in-memory event storage.
  It provides fast, atomic operations with ordered traversal capabilities.

  ## Features

  - Ordered event storage using `:ordered_set` tables
  - Atomic sequence generation with `:atomics`
  - Composite key indexing for efficient entity queries
  - Lock-free concurrent appends
  - Memory-efficient streaming

  ## Storage Structure

  - **Events table**: `{event_id, event}` - ordered by event_id
  - **Entity index**: `{{entity_id, event_id}, nil}` - composite key for range scans
  - **Sequence counter**: atomic counter for thread-safe ID generation

  ## References

  - ADR003: Event Store Architecture Decision
  - ADR004: PState Materialization from Events
  """

  @behaviour EventStore.Adapter

  @impl true
  def init(opts \\ []) do
    table_name = Keyword.get(opts, :table_name, :event_store)
    entity_index_name = :"#{table_name}_entity_idx"

    # Main events table: ordered by event_id
    # Use :public for cross-process access, :ordered_set for sequential scanning
    # Check if table already exists and clear it for idempotent initialization
    events =
      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [:ordered_set, :public, :named_table])

        existing_table ->
          :ets.delete_all_objects(existing_table)
          existing_table
      end

    # Entity index: {{entity_id, event_id}, nil}
    # Composite key allows efficient range scans by entity_id
    # Note: Entity index is not a named table, so we need to delete and recreate
    entity_index =
      case :ets.whereis(entity_index_name) do
        :undefined ->
          :ets.new(entity_index_name, [:ordered_set, :public, :named_table])

        existing_index ->
          :ets.delete_all_objects(existing_index)
          existing_index
      end

    # Atomic sequence counter for thread-safe ID generation
    sequence = :atomics.new(1, signed: false)

    state = %{
      events: events,
      entity_index: entity_index,
      sequence: sequence,
      table_name: table_name
    }

    {:ok, state}
  end

  @impl true
  def append(state, space_id, entity_id, event_type, payload, opts \\ []) do
    # TODO (RMX007_4A): Implement per-space sequences
    # This is a temporary stub - full implementation in Phase RMX007_4A
    # For now, use global sequence and hardcode space_sequence = event_id

    # Atomically increment sequence to get unique event_id
    event_id = :atomics.add_get(state.sequence, 1, 1)

    # Build event metadata
    metadata = %{
      event_id: event_id,
      space_id: space_id,
      space_sequence: event_id,
      entity_id: entity_id,
      event_type: event_type,
      timestamp: DateTime.utc_now(),
      causation_id: Keyword.get(opts, :causation_id),
      correlation_id: Keyword.get(opts, :correlation_id, generate_correlation_id())
    }

    event = %{metadata: metadata, payload: payload}

    # Store event in main table
    :ets.insert(state.events, {event_id, event})

    # Store entity index entry for efficient entity queries
    :ets.insert(state.entity_index, {{entity_id, event_id}, nil})

    {:ok, event_id, event_id, state}
  end

  @impl true
  def get_events(state, entity_id, opts \\ []) do
    from_sequence = Keyword.get(opts, :from_sequence, 0)
    limit = Keyword.get(opts, :limit, :infinity)

    # Use ETS match spec for efficient filtering
    # Match pattern: {{entity_id, event_id}, _} where event_id > from_sequence
    match_spec = [
      {{{entity_id, :"$1"}, :_}, [{:>, :"$1", from_sequence}], [:"$1"]}
    ]

    # Get event IDs matching the spec
    event_ids =
      case limit do
        :infinity ->
          :ets.select(state.entity_index, match_spec)

        n when is_integer(n) and n > 0 ->
          case :ets.select(state.entity_index, match_spec, n) do
            {ids, _continuation} -> ids
            :"$end_of_table" -> []
          end
      end

    # Fetch events from main table
    events =
      Enum.map(event_ids, fn id ->
        [{^id, event}] = :ets.lookup(state.events, id)
        event
      end)

    {:ok, events}
  end

  @impl true
  def get_event(state, event_id) do
    case :ets.lookup(state.events, event_id) do
      [{^event_id, event}] -> {:ok, event}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_all_events(state, opts \\ []) do
    from_sequence = Keyword.get(opts, :from_sequence, 0)
    limit = Keyword.get(opts, :limit, :infinity)

    # Match spec for all events with event_id > from_sequence
    match_spec = [
      {{:"$1", :"$2"}, [{:>, :"$1", from_sequence}], [:"$_"]}
    ]

    # Get events matching the spec
    rows =
      case limit do
        :infinity ->
          :ets.select(state.events, match_spec)

        n when is_integer(n) and n > 0 ->
          case :ets.select(state.events, match_spec, n) do
            {rows, _continuation} -> rows
            :"$end_of_table" -> []
          end
      end

    events = Enum.map(rows, fn {_id, event} -> event end)

    {:ok, events}
  end

  @impl true
  def stream_all_events(state, opts \\ []) do
    from_sequence = Keyword.get(opts, :from_sequence, 0)
    batch_size = Keyword.get(opts, :batch_size, 1000)

    Stream.resource(
      # Initialization: return starting sequence and continuation marker
      fn -> {from_sequence, :cont} end,
      # Iteration: fetch next batch of events
      fn
        {_current_seq, :halt} ->
          {:halt, nil}

        {current_seq, :cont} ->
          # Match spec for events with event_id > current_seq
          match_spec = [
            {{:"$1", :"$2"}, [{:>, :"$1", current_seq}], [:"$_"]}
          ]

          case :ets.select(state.events, match_spec, batch_size) do
            {rows, continuation} when is_list(rows) and rows != [] ->
              events = Enum.map(rows, fn {_id, event} -> event end)
              last_event = List.last(events)
              next_seq = last_event.metadata.event_id

              # Check if there are more results
              case continuation do
                :"$end_of_table" -> {events, {next_seq, :halt}}
                _ -> {events, {next_seq, :cont}}
              end

            :"$end_of_table" ->
              {:halt, nil}

            {[], _continuation} ->
              {:halt, nil}
          end
      end,
      # Cleanup: nothing to clean up
      fn _acc -> :ok end
    )
  end

  @impl true
  def get_latest_sequence(state) do
    # Get current value of atomic counter
    current = :atomics.get(state.sequence, 1)
    {:ok, current}
  end

  # Private helper to generate correlation IDs
  # Using a simple UUID v4 implementation
  defp generate_correlation_id do
    # Generate 16 random bytes
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)

    # Set version (4) and variant (2) bits
    <<u0::48, 4::4, u1::12, 2::2, u2::62>>
    |> binary_to_uuid_string()
  end

  defp binary_to_uuid_string(
         <<a1::4, a2::4, a3::4, a4::4, a5::4, a6::4, a7::4, a8::4, b1::4, b2::4, b3::4, b4::4,
           c1::4, c2::4, c3::4, c4::4, d1::4, d2::4, d3::4, d4::4, e1::4, e2::4, e3::4, e4::4,
           e5::4, e6::4, e7::4, e8::4, e9::4, e10::4, e11::4, e12::4>>
       ) do
    <<to_hex(a1), to_hex(a2), to_hex(a3), to_hex(a4), to_hex(a5), to_hex(a6), to_hex(a7),
      to_hex(a8), ?-, to_hex(b1), to_hex(b2), to_hex(b3), to_hex(b4), ?-, to_hex(c1), to_hex(c2),
      to_hex(c3), to_hex(c4), ?-, to_hex(d1), to_hex(d2), to_hex(d3), to_hex(d4), ?-, to_hex(e1),
      to_hex(e2), to_hex(e3), to_hex(e4), to_hex(e5), to_hex(e6), to_hex(e7), to_hex(e8),
      to_hex(e9), to_hex(e10), to_hex(e11), to_hex(e12)>>
  end

  defp to_hex(n) when n < 10, do: ?0 + n
  defp to_hex(n), do: ?a + n - 10

  @impl true
  def stream_space_events(state, space_id, opts \\ []) do
    # TODO (RMX007_4A): Implement space-aware streaming
    # This is a temporary stub - full implementation in Phase RMX007_4A
    # For now, filter all events by space_id from metadata

    from_sequence = Keyword.get(opts, :from_sequence, 0)
    batch_size = Keyword.get(opts, :batch_size, 1000)

    Stream.resource(
      fn -> from_sequence end,
      fn last_seq ->
        events =
          :ets.tab2list(state.events)
          |> Enum.filter(fn {event_id, event} ->
            event_id > last_seq and event.metadata.space_id == space_id
          end)
          |> Enum.sort_by(fn {event_id, _event} -> event_id end)
          |> Enum.take(batch_size)
          |> Enum.map(fn {_event_id, event} -> event end)

        case events do
          [] ->
            {:halt, last_seq}

          events ->
            new_last_seq = List.last(events).metadata.event_id
            {events, new_last_seq}
        end
      end,
      fn _last_seq -> :ok end
    )
  end

  @impl true
  def get_space_latest_sequence(state, space_id) do
    # TODO (RMX007_4A): Implement per-space sequence tracking
    # This is a temporary stub - full implementation in Phase RMX007_4A
    # For now, find the highest event_id for this space_id

    latest =
      :ets.tab2list(state.events)
      |> Enum.filter(fn {_event_id, event} -> event.metadata.space_id == space_id end)
      |> Enum.map(fn {_event_id, event} -> event.metadata.space_sequence end)
      |> Enum.max(fn -> 0 end)

    {:ok, latest}
  end
end
