defmodule EventStore.Adapters.SQLite do
  @moduledoc """
  SQLite-based event store adapter for production use.

  This adapter uses SQLite for persistent event storage with optimizations
  for append-heavy workloads and efficient querying.

  ## Features

  - Write-Ahead Logging (WAL) mode for better concurrency
  - Composite indexes for efficient entity queries
  - Binary compression for payload storage
  - Streaming support for large datasets
  - Persistent storage with ACID guarantees

  ## Storage Structure

  - **Events table**: Sequential event log with composite indexes
  - **Payload compression**: `:erlang.term_to_binary(payload, compressed: 6)`
  - **Indexes**: Composite (entity_id, event_id), event_type, correlation_id

  ## References

  - ADR003: Event Store Architecture Decision
  - ADR004: PState Materialization from Events
  """

  @behaviour EventStore.Adapter

  @impl true
  def init(opts \\ []) do
    database = Keyword.fetch!(opts, :database)

    case Exqlite.Sqlite3.open(database) do
      {:ok, db} ->
        # Optimize SQLite for append-heavy workload
        Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
        Exqlite.Sqlite3.execute(db, "PRAGMA synchronous=NORMAL")
        Exqlite.Sqlite3.execute(db, "PRAGMA cache_size=-64000")
        Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout=5000")

        # Create events table
        Exqlite.Sqlite3.execute(db, """
        CREATE TABLE IF NOT EXISTS events (
          event_id INTEGER PRIMARY KEY AUTOINCREMENT,
          entity_id TEXT NOT NULL,
          event_type TEXT NOT NULL,
          payload BLOB NOT NULL,
          timestamp INTEGER NOT NULL,
          causation_id INTEGER,
          correlation_id TEXT,
          created_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
        """)

        # Create composite index for entity queries
        Exqlite.Sqlite3.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_events_entity_id_event_id
        ON events(entity_id, event_id)
        """)

        # Create index for event type pattern queries
        Exqlite.Sqlite3.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_events_event_type
        ON events(event_type)
        """)

        # Create partial index for correlation tracing
        Exqlite.Sqlite3.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_events_correlation_id
        ON events(correlation_id) WHERE correlation_id IS NOT NULL
        """)

        {:ok, %{db: db}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def append(state, entity_id, event_type, payload, opts \\ []) do
    timestamp = DateTime.to_unix(DateTime.utc_now(), :millisecond)
    causation_id = Keyword.get(opts, :causation_id)
    correlation_id = Keyword.get(opts, :correlation_id, generate_correlation_id())

    # Compress payload using Erlang term_to_binary
    payload_bin = :erlang.term_to_binary(payload, compressed: 6)

    case Exqlite.Sqlite3.prepare(
           state.db,
           """
           INSERT INTO events (entity_id, event_type, payload, timestamp, causation_id, correlation_id)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6)
           """
         ) do
      {:ok, stmt} ->
        :ok =
          Exqlite.Sqlite3.bind(stmt, [
            entity_id,
            event_type,
            payload_bin,
            timestamp,
            causation_id,
            correlation_id
          ])

        case Exqlite.Sqlite3.step(state.db, stmt) do
          :done ->
            {:ok, event_id} = Exqlite.Sqlite3.last_insert_rowid(state.db)
            {:ok, event_id, state}

          :busy ->
            {:error, :database_busy}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_events(state, entity_id, opts \\ []) do
    from_sequence = Keyword.get(opts, :from_sequence, 0)
    limit = Keyword.get(opts, :limit, 1000)

    case Exqlite.Sqlite3.prepare(
           state.db,
           """
           SELECT event_id, entity_id, event_type, payload, timestamp, causation_id, correlation_id
           FROM events
           WHERE entity_id = ?1 AND event_id > ?2
           ORDER BY event_id ASC
           LIMIT ?3
           """
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [entity_id, from_sequence, limit])
        events = fetch_all_rows(state.db, stmt)
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_event(state, event_id) do
    case Exqlite.Sqlite3.prepare(
           state.db,
           """
           SELECT event_id, entity_id, event_type, payload, timestamp, causation_id, correlation_id
           FROM events
           WHERE event_id = ?1
           """
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [event_id])

        case Exqlite.Sqlite3.step(state.db, stmt) do
          {:row, row} -> {:ok, row_to_event(row)}
          :done -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_all_events(state, opts \\ []) do
    from_sequence = Keyword.get(opts, :from_sequence, 0)
    limit = Keyword.get(opts, :limit, 1000)

    case Exqlite.Sqlite3.prepare(
           state.db,
           """
           SELECT event_id, entity_id, event_type, payload, timestamp, causation_id, correlation_id
           FROM events
           WHERE event_id > ?1
           ORDER BY event_id ASC
           LIMIT ?2
           """
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [from_sequence, limit])
        events = fetch_all_rows(state.db, stmt)
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream_all_events(state, opts \\ []) do
    from_sequence = Keyword.get(opts, :from_sequence, 0)
    batch_size = Keyword.get(opts, :batch_size, 1000)

    Stream.resource(
      # Initialization: return starting sequence
      fn -> from_sequence end,
      # Iteration: fetch next batch of events
      fn current_seq ->
        case Exqlite.Sqlite3.prepare(
               state.db,
               """
               SELECT event_id, entity_id, event_type, payload, timestamp, causation_id, correlation_id
               FROM events
               WHERE event_id > ?1
               ORDER BY event_id ASC
               LIMIT ?2
               """
             ) do
          {:ok, stmt} ->
            :ok = Exqlite.Sqlite3.bind(stmt, [current_seq, batch_size])
            events = fetch_all_rows(state.db, stmt)

            if Enum.empty?(events) do
              {:halt, current_seq}
            else
              last_event = List.last(events)
              next_seq = last_event.metadata.event_id
              {events, next_seq}
            end

          {:error, _reason} ->
            {:halt, current_seq}
        end
      end,
      # Cleanup: nothing to clean up
      fn _acc -> :ok end
    )
  end

  @impl true
  def get_latest_sequence(state) do
    case Exqlite.Sqlite3.prepare(
           state.db,
           """
           SELECT MAX(event_id) FROM events
           """
         ) do
      {:ok, stmt} ->
        case Exqlite.Sqlite3.step(state.db, stmt) do
          {:row, [nil]} -> {:ok, 0}
          {:row, [event_id]} -> {:ok, event_id}
          :done -> {:ok, 0}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helper to fetch all rows from a prepared statement
  defp fetch_all_rows(db, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> fetch_all_rows(db, stmt, [row_to_event(row) | acc])
      :done -> Enum.reverse(acc)
      {:error, _reason} -> Enum.reverse(acc)
    end
  end

  # Private helper to convert row to event structure
  defp row_to_event([
         event_id,
         entity_id,
         event_type,
         payload_bin,
         timestamp,
         causation_id,
         correlation_id
       ]) do
    payload = :erlang.binary_to_term(payload_bin)
    timestamp_dt = DateTime.from_unix!(timestamp, :millisecond)

    %{
      metadata: %{
        event_id: event_id,
        entity_id: entity_id,
        event_type: event_type,
        timestamp: timestamp_dt,
        causation_id: causation_id,
        correlation_id: correlation_id
      },
      payload: payload
    }
  end

  # Private helper to generate correlation IDs
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
end
