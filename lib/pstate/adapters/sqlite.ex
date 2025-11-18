defmodule PState.Adapters.SQLite do
  @moduledoc """
  Durable SQLite storage adapter for PState with space support.

  This adapter uses SQLite for persistent key-value storage with space isolation.
  It's suitable for production applications where data needs to be persisted to disk
  and isolated by space (namespace) for multi-tenancy.

  ## Features

  - Durable storage (single file)
  - Space-scoped data isolation
  - WAL mode for better concurrency
  - Erlang term binary encoding/decoding
  - Prepared statements for performance
  - Updated timestamp tracking
  - Composite primary key (space_id, key)

  ## Options

  - `:path` - Path to SQLite database file (required)
  - `:table` - Table name (default: "pstate_entities")

  ## Examples

      iex> {:ok, state} = PState.Adapters.SQLite.init(path: "db.sqlite3")
      {:ok, %PState.Adapters.SQLite{conn: conn, table_name: "pstate_entities"}}

      iex> PState.Adapters.SQLite.put(state, 1, "key", %{data: "value"})
      :ok

      iex> PState.Adapters.SQLite.get(state, 1, "key")
      {:ok, %{"data" => "value"}}
  """

  @behaviour PState.Adapter

  defstruct [:conn, :table_name]

  @impl true
  def init(opts) do
    db_path = Keyword.fetch!(opts, :path)
    table_name = Keyword.get(opts, :table, "pstate_entities")

    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    # Enable WAL mode for better concurrency
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")

    # Create table with space_id support
    create_table_sql = """
    CREATE TABLE IF NOT EXISTS #{table_name} (
      space_id INTEGER NOT NULL,
      key TEXT NOT NULL,
      value BLOB NOT NULL,
      updated_at INTEGER DEFAULT (strftime('%s', 'now')),
      PRIMARY KEY (space_id, key)
    )
    """

    :ok = Exqlite.Sqlite3.execute(conn, create_table_sql)

    # Create index on space_id for efficient space queries
    index_space_sql =
      "CREATE INDEX IF NOT EXISTS idx_pstate_space ON #{table_name}(space_id)"

    :ok = Exqlite.Sqlite3.execute(conn, index_space_sql)

    state = %__MODULE__{conn: conn, table_name: table_name}
    {:ok, state}
  rescue
    error -> {:error, error}
  end

  @impl true
  def get(%__MODULE__{conn: conn, table_name: table}, space_id, key) do
    sql = "SELECT value FROM #{table} WHERE space_id = ?1 AND key = ?2"

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_id, key])

        result =
          case Exqlite.Sqlite3.step(conn, stmt) do
            {:row, [binary_value]} ->
              # Decode Erlang term from binary
              value = :erlang.binary_to_term(binary_value)
              {:ok, value}

            :done ->
              {:ok, nil}
          end

        :ok = Exqlite.Sqlite3.release(conn, stmt)
        result

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def put(%__MODULE__{conn: conn, table_name: table}, space_id, key, value) do
    # Encode Erlang term to binary
    binary_value = :erlang.term_to_binary(value)

    sql = """
    INSERT INTO #{table} (space_id, key, value)
    VALUES (?1, ?2, ?3)
    ON CONFLICT(space_id, key) DO UPDATE SET value = ?3, updated_at = strftime('%s', 'now')
    """

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_id, key, binary_value])
        :done = Exqlite.Sqlite3.step(conn, stmt)
        :ok = Exqlite.Sqlite3.release(conn, stmt)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def delete(%__MODULE__{conn: conn, table_name: table}, space_id, key) do
    sql = "DELETE FROM #{table} WHERE space_id = ?1 AND key = ?2"

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_id, key])
        :done = Exqlite.Sqlite3.step(conn, stmt)
        :ok = Exqlite.Sqlite3.release(conn, stmt)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def scan(%__MODULE__{conn: conn, table_name: table}, space_id, prefix, _opts) do
    sql = "SELECT key, value FROM #{table} WHERE space_id = ?1 AND key LIKE ?2"
    pattern = "#{prefix}%"

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [space_id, pattern])
        results = collect_kv_rows(conn, stmt, [])
        :ok = Exqlite.Sqlite3.release(conn, stmt)
        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def multi_get(%__MODULE__{conn: conn, table_name: table}, space_id, keys) do
    if keys == [] do
      {:ok, %{}}
    else
      placeholders = Enum.map_join(2..(length(keys) + 1), ", ", &"?#{&1}")
      sql = "SELECT key, value FROM #{table} WHERE space_id = ?1 AND key IN (#{placeholders})"

      case Exqlite.Sqlite3.prepare(conn, sql) do
        {:ok, stmt} ->
          :ok = Exqlite.Sqlite3.bind(stmt, [space_id | keys])
          results = collect_kv_map(conn, stmt, %{})
          :ok = Exqlite.Sqlite3.release(conn, stmt)
          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def multi_put(%__MODULE__{conn: conn, table_name: table}, space_id, entries) do
    if entries == [] do
      :ok
    else
      # Start transaction
      :ok = Exqlite.Sqlite3.execute(conn, "BEGIN TRANSACTION")

      sql = """
      INSERT INTO #{table} (space_id, key, value)
      VALUES (?1, ?2, ?3)
      ON CONFLICT(space_id, key) DO UPDATE SET value = ?3, updated_at = strftime('%s', 'now')
      """

      try do
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

        Enum.each(entries, fn {key, value} ->
          # Encode Erlang term to binary (consistent with put/4)
          binary_value = :erlang.term_to_binary(value)
          :ok = Exqlite.Sqlite3.bind(stmt, [space_id, key, binary_value])
          :done = Exqlite.Sqlite3.step(conn, stmt)
          :ok = Exqlite.Sqlite3.reset(stmt)
        end)

        :ok = Exqlite.Sqlite3.release(conn, stmt)
        :ok = Exqlite.Sqlite3.execute(conn, "COMMIT")
        :ok
      rescue
        e ->
          :ok = Exqlite.Sqlite3.execute(conn, "ROLLBACK")
          {:error, e}
      end
    end
  rescue
    error -> {:error, error}
  end

  # Helpers

  defp collect_kv_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [key, binary_value]} ->
        # Decode Erlang term from binary
        value = :erlang.binary_to_term(binary_value)
        collect_kv_rows(conn, stmt, [{key, value} | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  defp collect_kv_map(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [key, binary_value]} ->
        # Decode Erlang term from binary
        value = :erlang.binary_to_term(binary_value)
        collect_kv_map(conn, stmt, Map.put(acc, key, value))

      :done ->
        acc
    end
  end

  @impl true
  def close(%__MODULE__{conn: conn}) do
    case Exqlite.Sqlite3.close(conn) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
