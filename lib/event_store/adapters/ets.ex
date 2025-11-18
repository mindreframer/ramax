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
  - **Space index**: `{{space_id, space_sequence, event_id}, nil}` - for space-scoped queries
  - **Sequence counter**: atomic counter for thread-safe global ID generation
  - **Space sequences**: `{space_id, atomic_ref}` - per-space sequence counters

  ## References

  - ADR003: Event Store Architecture Decision
  - ADR004: PState Materialization from Events
  - ADR005: Space Support Architecture Decision
  """

  @behaviour EventStore.Adapter

  @impl true
  def init(opts \\ []) do
    table_name = Keyword.get(opts, :table_name, :event_store)
    entity_index_name = :"#{table_name}_entity_idx"
    space_index_name = :"#{table_name}_space_idx"
    space_sequences_name = :"#{table_name}_space_seq"

    # Main events table: ordered by event_id
    # Use :public for cross-process access, :ordered_set for sequential scanning
    # Check if table already exists and reuse it (for shared table scenarios)
    events =
      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [:ordered_set, :public, :named_table])

        existing_table ->
          # Reuse existing table without clearing (supports multi-space sharing)
          existing_table
      end

    # Entity index: {{entity_id, event_id}, nil}
    # Composite key allows efficient range scans by entity_id
    entity_index =
      case :ets.whereis(entity_index_name) do
        :undefined ->
          :ets.new(entity_index_name, [:ordered_set, :public, :named_table])

        existing_index ->
          # Reuse existing index without clearing
          existing_index
      end

    # Space index: {{space_id, space_sequence, event_id}, nil}
    # Composite key allows efficient space-scoped range scans
    space_index =
      case :ets.whereis(space_index_name) do
        :undefined ->
          :ets.new(space_index_name, [:ordered_set, :public, :named_table])

        existing_index ->
          # Reuse existing index without clearing
          existing_index
      end

    # Space sequences: {space_id, atomic_ref}
    # Each space has its own atomic counter for independent sequence tracking
    space_sequences =
      case :ets.whereis(space_sequences_name) do
        :undefined ->
          :ets.new(space_sequences_name, [:set, :public, :named_table])

        existing_table ->
          # Reuse existing table without clearing
          existing_table
      end

    # Atomic sequence counter for thread-safe global ID generation
    # Store in a dedicated ETS table for persistence across multiple EventStore instances
    sequence_table_name = :"#{table_name}_sequence"

    sequence =
      case :ets.whereis(sequence_table_name) do
        :undefined ->
          # Create new table and atomic counter
          :ets.new(sequence_table_name, [:set, :public, :named_table])
          atomic = :atomics.new(1, signed: false)
          :ets.insert(sequence_table_name, {:sequence, atomic})
          atomic

        _existing ->
          # Reuse existing atomic counter from table
          [{:sequence, atomic}] = :ets.lookup(sequence_table_name, :sequence)
          atomic
      end

    state = %{
      events: events,
      entity_index: entity_index,
      space_index: space_index,
      space_sequences: space_sequences,
      sequence: sequence,
      table_name: table_name
    }

    {:ok, state}
  end

  @impl true
  def append(state, space_id, entity_id, event_type, payload, opts \\ []) do
    # Atomically increment global sequence to get unique event_id
    event_id = :atomics.add_get(state.sequence, 1, 1)

    # Atomically increment space-specific sequence
    space_sequence = get_and_increment_space_sequence(state, space_id)

    # Build event metadata
    metadata = %{
      event_id: event_id,
      space_id: space_id,
      space_sequence: space_sequence,
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

    # Store space index entry for efficient space-scoped queries
    :ets.insert(state.space_index, {{space_id, space_sequence, event_id}, nil})

    {:ok, event_id, space_sequence, state}
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

  # Private helper to get and increment space sequence atomically
  # Creates a new atomic counter for the space if it doesn't exist
  # Uses :ets.insert_new for atomic creation to avoid race conditions
  defp get_and_increment_space_sequence(state, space_id) do
    case :ets.lookup(state.space_sequences, space_id) do
      [{^space_id, atomic_ref}] ->
        # Space exists, increment its atomic counter
        :atomics.add_get(atomic_ref, 1, 1)

      [] ->
        # Space doesn't exist, try to create new atomic counter atomically
        atomic_ref = :atomics.new(1, signed: false)

        case :ets.insert_new(state.space_sequences, {space_id, atomic_ref}) do
          true ->
            # Successfully inserted, we're the first one, use this atomic ref
            :atomics.add_get(atomic_ref, 1, 1)

          false ->
            # Someone else created it in the meantime, look it up again
            [{^space_id, existing_ref}] = :ets.lookup(state.space_sequences, space_id)
            :atomics.add_get(existing_ref, 1, 1)
        end
    end
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
    from_sequence = Keyword.get(opts, :from_sequence, 0)
    batch_size = Keyword.get(opts, :batch_size, 1000)

    Stream.resource(
      # Initialization: return starting sequence and continuation marker
      fn -> {from_sequence, :cont} end,
      # Iteration: fetch next batch of events for this space
      fn
        {_current_seq, :halt} ->
          {:halt, nil}

        {current_seq, :cont} ->
          # Match spec for space events with space_sequence > current_seq
          # Pattern: {{space_id, space_sequence, event_id}, _}
          match_spec = [
            {{{space_id, :"$1", :"$2"}, :_}, [{:>, :"$1", current_seq}], [{{:"$1", :"$2"}}]}
          ]

          case :ets.select(state.space_index, match_spec, batch_size) do
            {rows, continuation} when is_list(rows) and rows != [] ->
              # Fetch actual events from main table using event_ids
              events =
                Enum.map(rows, fn {_space_seq, event_id} ->
                  [{^event_id, event}] = :ets.lookup(state.events, event_id)
                  event
                end)

              last_event = List.last(events)
              next_seq = last_event.metadata.space_sequence

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
  def get_space_latest_sequence(state, space_id) do
    case :ets.lookup(state.space_sequences, space_id) do
      [{^space_id, atomic_ref}] ->
        # Space exists, get current value of atomic counter
        current = :atomics.get(atomic_ref, 1)
        {:ok, current}

      [] ->
        # Space doesn't exist yet, return 0
        {:ok, 0}
    end
  end

  # Space management helpers for ETS adapter
  # Note: ETS doesn't persist spaces, they're created on-demand during event append

  @doc """
  Insert a new space into the in-memory registry.
  For ETS, we create a simple in-memory representation.
  Returns {:ok, space_id}.
  """
  def insert_space(state, space_name, metadata) do
    # For ETS, we use a simple incrementing ID based on table name hash
    # This ensures uniqueness within the same test session
    space_id = :erlang.phash2({state.table_name, space_name})

    # Store in a spaces table (create if needed)
    spaces_table = ensure_spaces_table(state.table_name)
    :ets.insert(spaces_table, {space_id, space_name, metadata})

    {:ok, space_id}
  end

  @doc """
  Get space by name from ETS.
  Returns {:ok, %Ramax.Space{}} or {:error, :not_found}.
  """
  def get_space_by_name(state, space_name) do
    spaces_table = ensure_spaces_table(state.table_name)

    # Scan for space with matching name
    case :ets.match(spaces_table, {:"$1", space_name, :"$2"}) do
      [[space_id, metadata]] ->
        space = %Ramax.Space{
          space_id: space_id,
          space_name: space_name,
          metadata: metadata
        }

        {:ok, space}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Get space by ID from ETS.
  Returns {:ok, %Ramax.Space{}} or {:error, :not_found}.
  """
  def get_space_by_id(state, space_id) do
    spaces_table = ensure_spaces_table(state.table_name)

    case :ets.lookup(spaces_table, space_id) do
      [{^space_id, space_name, metadata}] ->
        space = %Ramax.Space{
          space_id: space_id,
          space_name: space_name,
          metadata: metadata
        }

        {:ok, space}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  List all spaces from ETS.
  Returns {:ok, [%Ramax.Space{}, ...]}.
  """
  def list_all_spaces(state) do
    spaces_table = ensure_spaces_table(state.table_name)

    spaces =
      :ets.tab2list(spaces_table)
      |> Enum.map(fn {space_id, space_name, metadata} ->
        %Ramax.Space{
          space_id: space_id,
          space_name: space_name,
          metadata: metadata
        }
      end)
      |> Enum.sort_by(& &1.space_id)

    {:ok, spaces}
  end

  @doc """
  Delete a space and cascade all related data in ETS.
  """
  def delete_space(state, space_id) do
    # Delete all events for this space
    :ets.match_delete(state.events, {:"$1", %{metadata: %{space_id: space_id}}})

    # Delete from space index
    :ets.match_delete(state.space_index, {{space_id, :"$1", :"$2"}, nil})

    # Delete space sequence
    :ets.delete(state.space_sequences, space_id)

    # Delete from spaces table
    spaces_table = ensure_spaces_table(state.table_name)
    :ets.delete(spaces_table, space_id)

    :ok
  end

  # Projection checkpoint management for ETS

  @doc """
  Get the projection checkpoint for a space from ETS.
  Returns {:ok, space_sequence} or {:error, :not_found}.
  """
  def get_projection_checkpoint(state, space_id) do
    checkpoints_table = ensure_checkpoints_table(state.table_name)

    case :ets.lookup(checkpoints_table, space_id) do
      [{^space_id, _event_id, space_sequence, _updated_at}] ->
        {:ok, space_sequence}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Update the projection checkpoint for a space in ETS.
  """
  def update_projection_checkpoint(state, space_id, space_sequence) do
    checkpoints_table = ensure_checkpoints_table(state.table_name)

    # Find the event_id for this space_sequence
    event_id = find_event_id_for_space_sequence(state, space_id, space_sequence)

    timestamp = :os.system_time(:second)
    :ets.insert(checkpoints_table, {space_id, event_id, space_sequence, timestamp})

    :ok
  end

  # Private helpers

  defp ensure_spaces_table(base_table_name) do
    table_name = :"#{base_table_name}_spaces"

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:set, :public, :named_table])

      existing_table ->
        existing_table
    end
  end

  defp ensure_checkpoints_table(base_table_name) do
    table_name = :"#{base_table_name}_checkpoints"

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:set, :public, :named_table])

      existing_table ->
        existing_table
    end
  end

  defp find_event_id_for_space_sequence(state, space_id, space_sequence) do
    # Find event with matching space_id and space_sequence
    pattern = {:"$1", %{metadata: %{space_id: space_id, space_sequence: space_sequence}}}

    case :ets.match(state.events, pattern) do
      [[event_id]] -> event_id
      [] -> 0
    end
  end

  @impl true
  def close(_state) do
    # ETS tables are automatically cleaned up when the process terminates
    # No explicit cleanup needed
    :ok
  end
end
