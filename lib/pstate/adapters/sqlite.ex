defmodule PState.Adapters.SQLite do
  @moduledoc """
  Durable SQLite storage adapter for PState.

  This adapter uses SQLite for persistent key-value storage. It's suitable for
  production applications where data needs to be persisted to disk.

  ## Features

  - Durable storage (single file)
  - WAL mode for better concurrency
  - Erlang term binary encoding/decoding
  - Prepared statements for performance
  - Updated timestamp tracking

  ## Options

  - `:path` - Path to SQLite database file (required)
  - `:table` - Table name (default: "pstate_entities")

  ## Examples

      iex> {:ok, state} = PState.Adapters.SQLite.init(path: "db.sqlite3")
      {:ok, %PState.Adapters.SQLite{conn: conn, table_name: "pstate_entities"}}

      iex> PState.Adapters.SQLite.put(state, "key", %{data: "value"})
      :ok

      iex> PState.Adapters.SQLite.get(state, "key")
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

    # Create table
    create_table_sql = """
    CREATE TABLE IF NOT EXISTS #{table_name} (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at INTEGER DEFAULT (strftime('%s', 'now'))
    )
    """

    :ok = Exqlite.Sqlite3.execute(conn, create_table_sql)

    # Create index on updated_at for scan operations
    index_sql =
      "CREATE INDEX IF NOT EXISTS idx_updated_at ON #{table_name}(updated_at)"

    :ok = Exqlite.Sqlite3.execute(conn, index_sql)

    state = %__MODULE__{conn: conn, table_name: table_name}
    {:ok, state}
  rescue
    error -> {:error, error}
  end

  @impl true
  def get(%__MODULE__{conn: conn, table_name: table}, key) do
    sql = "SELECT value FROM #{table} WHERE key = ?1"

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [key])

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
  def put(%__MODULE__{conn: conn, table_name: table}, key, value) do
    # Encode Erlang term to binary
    binary_value = :erlang.term_to_binary(value)

    sql = """
    INSERT INTO #{table} (key, value)
    VALUES (?1, ?2)
    ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = strftime('%s', 'now')
    """

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [key, binary_value])
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
  def delete(%__MODULE__{conn: conn, table_name: table}, key) do
    sql = "DELETE FROM #{table} WHERE key = ?1"

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [key])
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
  def scan(%__MODULE__{conn: conn, table_name: table}, prefix, _opts) do
    sql = "SELECT key, value FROM #{table} WHERE key LIKE ?1"
    pattern = "#{prefix}%"

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [pattern])
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
  def multi_get(%__MODULE__{conn: conn, table_name: table}, keys) do
    if keys == [] do
      {:ok, %{}}
    else
      placeholders = Enum.map_join(1..length(keys), ", ", &"?#{&1}")
      sql = "SELECT key, value FROM #{table} WHERE key IN (#{placeholders})"

      case Exqlite.Sqlite3.prepare(conn, sql) do
        {:ok, stmt} ->
          :ok = Exqlite.Sqlite3.bind(stmt, keys)
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
  def multi_put(%__MODULE__{conn: conn, table_name: table}, entries) do
    if entries == [] do
      :ok
    else
      # Start transaction
      :ok = Exqlite.Sqlite3.execute(conn, "BEGIN TRANSACTION")

      sql = """
      INSERT INTO #{table} (key, value)
      VALUES (?1, ?2)
      ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = strftime('%s', 'now')
      """

      try do
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

        Enum.each(entries, fn {key, value} ->
          # Encode Erlang term to binary (consistent with put/3)
          binary_value = :erlang.term_to_binary(value)
          :ok = Exqlite.Sqlite3.bind(stmt, [key, binary_value])
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
end
