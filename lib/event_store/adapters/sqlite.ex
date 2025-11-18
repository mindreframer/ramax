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
          space_id INTEGER NOT NULL,
          space_sequence INTEGER NOT NULL,
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

        # Create index for space-based queries ordered by space_sequence
        Exqlite.Sqlite3.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_events_space_seq
        ON events(space_id, space_sequence)
        """)

        # Create composite index for space-entity queries
        Exqlite.Sqlite3.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_events_space_entity
        ON events(space_id, entity_id, event_id)
        """)

        # Create spaces table for space registry
        Exqlite.Sqlite3.execute(db, """
        CREATE TABLE IF NOT EXISTS spaces (
          space_id INTEGER PRIMARY KEY AUTOINCREMENT,
          space_name TEXT UNIQUE NOT NULL,
          created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
          metadata TEXT
        )
        """)

        # Create index for space name lookups
        Exqlite.Sqlite3.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_spaces_name
        ON spaces(space_name)
        """)

        # Create space_sequences table for per-space event sequences
        Exqlite.Sqlite3.execute(db, """
        CREATE TABLE IF NOT EXISTS space_sequences (
          space_id INTEGER PRIMARY KEY,
          last_sequence INTEGER NOT NULL DEFAULT 0
        )
        """)

        {:ok, %{db: db}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def append(state, space_id, entity_id, event_type, payload, opts \\ []) do
    timestamp = DateTime.to_unix(DateTime.utc_now(), :millisecond)
    causation_id = Keyword.get(opts, :causation_id)
    correlation_id = Keyword.get(opts, :correlation_id, generate_correlation_id())

    # Compress payload using Erlang term_to_binary
    payload_bin = :erlang.term_to_binary(payload, compressed: 6)

    # Begin transaction to ensure atomic space_sequence increment
    case Exqlite.Sqlite3.execute(state.db, "BEGIN TRANSACTION") do
      :ok ->
        # Get and increment space sequence for this space
        space_sequence = get_and_increment_space_sequence(state.db, space_id)

        # Insert event with space_id and space_sequence
        case Exqlite.Sqlite3.prepare(
               state.db,
               """
               INSERT INTO events (space_id, space_sequence, entity_id, event_type, payload, timestamp, causation_id, correlation_id)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
               """
             ) do
          {:ok, stmt} ->
            :ok =
              Exqlite.Sqlite3.bind(stmt, [
                space_id,
                space_sequence,
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

                # Commit transaction
                case Exqlite.Sqlite3.execute(state.db, "COMMIT") do
                  :ok ->
                    {:ok, event_id, space_sequence, state}

                  {:error, reason} ->
                    Exqlite.Sqlite3.execute(state.db, "ROLLBACK")
                    {:error, reason}
                end

              :busy ->
                Exqlite.Sqlite3.execute(state.db, "ROLLBACK")
                {:error, :database_busy}

              {:error, reason} ->
                Exqlite.Sqlite3.execute(state.db, "ROLLBACK")
                {:error, reason}
            end

          {:error, reason} ->
            Exqlite.Sqlite3.execute(state.db, "ROLLBACK")
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
           SELECT event_id, space_id, space_sequence, entity_id, event_type, payload, timestamp, causation_id, correlation_id
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
           SELECT event_id, space_id, space_sequence, entity_id, event_type, payload, timestamp, causation_id, correlation_id
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
           SELECT event_id, space_id, space_sequence, entity_id, event_type, payload, timestamp, causation_id, correlation_id
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
               SELECT event_id, space_id, space_sequence, entity_id, event_type, payload, timestamp, causation_id, correlation_id
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
         space_id,
         space_sequence,
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
        space_id: space_id,
        space_sequence: space_sequence,
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

  # Space sequence management

  # Private helper: Get and increment the space_sequence for a given space_id.
  #
  # This function:
  # 1. Ensures a row exists in space_sequences for this space_id
  # 2. Atomically increments the sequence
  # 3. Returns the new space_sequence.
  defp get_and_increment_space_sequence(db, space_id) do
    # Insert a row if it doesn't exist (with last_sequence = 0)
    case Exqlite.Sqlite3.prepare(
           db,
           "INSERT OR IGNORE INTO space_sequences (space_id, last_sequence) VALUES (?1, 0)"
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_id])
        Exqlite.Sqlite3.step(db, stmt)

      {:error, _reason} ->
        :ok
    end

    # Increment the sequence
    case Exqlite.Sqlite3.prepare(
           db,
           "UPDATE space_sequences SET last_sequence = last_sequence + 1 WHERE space_id = ?1"
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_id])
        Exqlite.Sqlite3.step(db, stmt)

      {:error, _reason} ->
        :ok
    end

    # Get the new sequence
    case Exqlite.Sqlite3.prepare(
           db,
           "SELECT last_sequence FROM space_sequences WHERE space_id = ?1"
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_id])

        case Exqlite.Sqlite3.step(db, stmt) do
          {:row, [sequence]} -> sequence
          _ -> 1
        end

      {:error, _reason} ->
        1
    end
  end

  # Space management helpers

  @doc """
  Insert a new space into the registry.

  Returns {:ok, space_id} on success.
  """
  def insert_space(state, space_name, metadata) do
    timestamp = :os.system_time(:second)
    metadata_json = if metadata, do: Jason.encode!(metadata), else: nil

    case Exqlite.Sqlite3.prepare(
           state.db,
           """
           INSERT INTO spaces (space_name, created_at, metadata)
           VALUES (?1, ?2, ?3)
           """
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_name, timestamp, metadata_json])

        case Exqlite.Sqlite3.step(state.db, stmt) do
          :done ->
            {:ok, space_id} = Exqlite.Sqlite3.last_insert_rowid(state.db)
            {:ok, space_id}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get space by name.

  Returns {:ok, %Ramax.Space{}} or {:error, :not_found}.
  """
  def get_space_by_name(state, space_name) do
    case Exqlite.Sqlite3.prepare(
           state.db,
           """
           SELECT space_id, space_name, metadata
           FROM spaces
           WHERE space_name = ?1
           """
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_name])

        case Exqlite.Sqlite3.step(state.db, stmt) do
          {:row, [space_id, space_name, metadata_json]} ->
            metadata =
              if metadata_json do
                Jason.decode!(metadata_json)
              else
                nil
              end

            space = %Ramax.Space{
              space_id: space_id,
              space_name: space_name,
              metadata: metadata
            }

            {:ok, space}

          :done ->
            {:error, :not_found}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get space by ID.

  Returns {:ok, %Ramax.Space{}} or {:error, :not_found}.
  """
  def get_space_by_id(state, space_id) do
    case Exqlite.Sqlite3.prepare(
           state.db,
           """
           SELECT space_id, space_name, metadata
           FROM spaces
           WHERE space_id = ?1
           """
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_id])

        case Exqlite.Sqlite3.step(state.db, stmt) do
          {:row, [space_id, space_name, metadata_json]} ->
            metadata =
              if metadata_json do
                Jason.decode!(metadata_json)
              else
                nil
              end

            space = %Ramax.Space{
              space_id: space_id,
              space_name: space_name,
              metadata: metadata
            }

            {:ok, space}

          :done ->
            {:error, :not_found}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all spaces ordered by space_id.

  Returns {:ok, [%Ramax.Space{}, ...]}.
  """
  def list_all_spaces(state) do
    case Exqlite.Sqlite3.prepare(
           state.db,
           """
           SELECT space_id, space_name, metadata
           FROM spaces
           ORDER BY space_id ASC
           """
         ) do
      {:ok, stmt} ->
        spaces = fetch_all_spaces(state.db, stmt)
        {:ok, spaces}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delete a space and cascade all related data.

  Removes:
  - Space record
  - Space sequence
  - All events in this space
  - All PState data in this space (will be added in Phase 5)
  - Projection checkpoints (will be added in Phase 6)
  """
  def delete_space(state, space_id) do
    # Use a transaction for atomic deletion
    case Exqlite.Sqlite3.execute(state.db, "BEGIN TRANSACTION") do
      :ok ->
        # Delete all events for this space
        delete_query(state.db, "DELETE FROM events WHERE space_id = ?1", [space_id])

        # Delete space sequences
        delete_query(state.db, "DELETE FROM space_sequences WHERE space_id = ?1", [space_id])

        # Delete the space itself
        delete_query(state.db, "DELETE FROM spaces WHERE space_id = ?1", [space_id])

        # Commit transaction
        case Exqlite.Sqlite3.execute(state.db, "COMMIT") do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helper to execute DELETE queries
  defp delete_query(db, query, params) do
    case Exqlite.Sqlite3.prepare(db, query) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, params)
        Exqlite.Sqlite3.step(db, stmt)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # Private helper to fetch all space rows
  defp fetch_all_spaces(db, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [space_id, space_name, metadata_json]} ->
        metadata =
          if metadata_json do
            Jason.decode!(metadata_json)
          else
            nil
          end

        space = %Ramax.Space{
          space_id: space_id,
          space_name: space_name,
          metadata: metadata
        }

        fetch_all_spaces(db, stmt, [space | acc])

      :done ->
        Enum.reverse(acc)

      {:error, _reason} ->
        Enum.reverse(acc)
    end
  end

  @impl true
  def stream_space_events(state, space_id, opts \\ []) do
    from_sequence = Keyword.get(opts, :from_sequence, 0)
    batch_size = Keyword.get(opts, :batch_size, 1000)

    Stream.resource(
      # Initialization: return starting sequence
      fn -> from_sequence end,
      # Iteration: fetch next batch of events for this space
      fn current_seq ->
        case Exqlite.Sqlite3.prepare(
               state.db,
               """
               SELECT event_id, space_id, space_sequence, entity_id, event_type, payload, timestamp, causation_id, correlation_id
               FROM events
               WHERE space_id = ?1 AND space_sequence > ?2
               ORDER BY space_sequence ASC
               LIMIT ?3
               """
             ) do
          {:ok, stmt} ->
            :ok = Exqlite.Sqlite3.bind(stmt, [space_id, current_seq, batch_size])
            events = fetch_all_rows(state.db, stmt)

            if Enum.empty?(events) do
              {:halt, current_seq}
            else
              last_event = List.last(events)
              next_seq = last_event.metadata.space_sequence
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
  def get_space_latest_sequence(state, space_id) do
    case Exqlite.Sqlite3.prepare(
           state.db,
           "SELECT last_sequence FROM space_sequences WHERE space_id = ?1"
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_id])

        case Exqlite.Sqlite3.step(state.db, stmt) do
          {:row, [last_sequence]} -> {:ok, last_sequence}
          :done -> {:ok, 0}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
