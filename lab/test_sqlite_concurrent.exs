#!/usr/bin/env elixir

# Test concurrent SQLite writes with separate connections
# This will help us understand the database_busy issue

Mix.install([
  {:exqlite, "~> 0.11"}
])

defmodule SQLiteTest do
  def test_concurrent_writes do
    db_path = "data/test_concurrent.db"
    File.mkdir_p!("data")

    try do
      File.rm(db_path)
    rescue
      _ -> :ok
    end

    # Open two separate connections to the same database
    {:ok, conn1} = Exqlite.Sqlite3.open(db_path)
    {:ok, conn2} = Exqlite.Sqlite3.open(db_path)

    # Enable WAL mode and set busy timeout
    Exqlite.Sqlite3.execute(conn1, "PRAGMA journal_mode=WAL")
    Exqlite.Sqlite3.execute(conn1, "PRAGMA busy_timeout=5000")
    Exqlite.Sqlite3.execute(conn2, "PRAGMA journal_mode=WAL")
    Exqlite.Sqlite3.execute(conn2, "PRAGMA busy_timeout=5000")

    # Create table
    Exqlite.Sqlite3.execute(conn1, """
    CREATE TABLE IF NOT EXISTS test_table (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      value TEXT NOT NULL
    )
    """)

    IO.puts("✓ Created table")

    # Test 1: Sequential writes
    IO.puts("\n--- Test 1: Sequential writes ---")

    Exqlite.Sqlite3.execute(conn1, "BEGIN")
    Exqlite.Sqlite3.execute(conn1, "INSERT INTO test_table (value) VALUES ('conn1-1')")
    Exqlite.Sqlite3.execute(conn1, "COMMIT")
    IO.puts("✓ Conn1 write 1 succeeded")

    Exqlite.Sqlite3.execute(conn2, "BEGIN")
    Exqlite.Sqlite3.execute(conn2, "INSERT INTO test_table (value) VALUES ('conn2-1')")
    result = Exqlite.Sqlite3.execute(conn2, "COMMIT")
    IO.puts("✓ Conn2 write 1 succeeded: #{inspect(result)}")

    # Test 2: Rapid sequential writes
    IO.puts("\n--- Test 2: Rapid sequential writes ---")

    Exqlite.Sqlite3.execute(conn1, "BEGIN")
    Exqlite.Sqlite3.execute(conn1, "INSERT INTO test_table (value) VALUES ('conn1-2')")
    Exqlite.Sqlite3.execute(conn1, "COMMIT")
    IO.puts("✓ Conn1 write 2 succeeded")

    # Immediately try conn2
    result = Exqlite.Sqlite3.execute(conn2, "BEGIN")
    IO.puts("Conn2 BEGIN result: #{inspect(result)}")

    result = Exqlite.Sqlite3.execute(conn2, "INSERT INTO test_table (value) VALUES ('conn2-2')")
    IO.puts("Conn2 INSERT result: #{inspect(result)}")

    result = Exqlite.Sqlite3.execute(conn2, "COMMIT")
    IO.puts("Conn2 COMMIT result: #{inspect(result)}")

    # Check results
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn1, "SELECT COUNT(*) FROM test_table")
    Exqlite.Sqlite3.bind(stmt, [])
    {:row, [count]} = Exqlite.Sqlite3.step(conn1, stmt)
    Exqlite.Sqlite3.release(conn1, stmt)

    IO.puts("\n✓ Total rows: #{count}")

    # Cleanup
    try do
      File.rm(db_path)
    rescue
      _ -> :ok
    end
  end
end

SQLiteTest.test_concurrent_writes()
