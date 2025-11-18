defmodule PState.Adapters.ETS do
  @moduledoc """
  ETS-based storage adapter for PState with space support.

  This adapter uses Erlang's ETS (Erlang Term Storage) for in-memory
  key-value storage with space isolation. It's suitable for development,
  testing, and single-node applications where persistence is not required.

  ## Features

  - Fast in-memory storage
  - Space-scoped data isolation
  - Read concurrency enabled
  - Public table access
  - Automatic cleanup on process termination
  - Composite key (space_id, key)

  ## Options

  - `:table_name` - Name of the ETS table (default: `:pstate_ets`)

  ## Examples

      iex> {:ok, state} = PState.Adapters.ETS.init(table_name: :my_table)
      {:ok, %{table: #Reference<...>}}

      iex> PState.Adapters.ETS.put(state, 1, "key", "value")
      :ok

      iex> PState.Adapters.ETS.get(state, 1, "key")
      {:ok, "value"}
  """

  @behaviour PState.Adapter

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, :pstate_ets)

    # Check if a named table already exists (for shared table scenarios)
    # If it does, reuse it; otherwise create a new one
    table =
      case :ets.whereis(table_name) do
        :undefined ->
          # Create new ETS table with :named_table for sharing across spaces
          :ets.new(table_name, [
            :set,
            :public,
            :named_table,
            {:read_concurrency, true}
          ])

        existing_table ->
          # Reuse existing named table
          existing_table
      end

    {:ok, %{table: table}}
  rescue
    error -> {:error, error}
  end

  @impl true
  def get(state, space_id, key) do
    composite_key = {space_id, key}

    case :ets.lookup(state.table, composite_key) do
      [{^composite_key, value}] -> {:ok, value}
      [] -> {:ok, nil}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def put(state, space_id, key, value) do
    composite_key = {space_id, key}
    true = :ets.insert(state.table, {composite_key, value})
    :ok
  rescue
    error -> {:error, error}
  end

  @impl true
  def delete(state, space_id, key) do
    composite_key = {space_id, key}
    true = :ets.delete(state.table, composite_key)
    :ok
  rescue
    error -> {:error, error}
  end

  @impl true
  def scan(state, space_id, prefix, _opts) do
    # Match on composite keys for the given space_id
    # Pattern: {{space_id, key}, value}
    matches = :ets.match(state.table, {{space_id, :"$1"}, :"$2"})

    results =
      matches
      |> Enum.filter(fn [key, _value] ->
        # Convert key to string for comparison if it's not already
        key_str = to_string(key)
        String.starts_with?(key_str, prefix)
      end)
      |> Enum.map(fn [key, value] -> {key, value} end)

    {:ok, results}
  rescue
    error -> {:error, error}
  end

  @impl true
  def multi_get(state, space_id, keys) when is_list(keys) do
    results =
      keys
      |> Enum.reduce(%{}, fn key, acc ->
        composite_key = {space_id, key}

        case :ets.lookup(state.table, composite_key) do
          [{^composite_key, value}] -> Map.put(acc, key, value)
          [] -> acc
        end
      end)

    {:ok, results}
  rescue
    error -> {:error, error}
  end

  @impl true
  def multi_put(state, space_id, entries) when is_list(entries) do
    # Convert entries to use composite keys
    composite_entries =
      Enum.map(entries, fn {key, value} ->
        {{space_id, key}, value}
      end)

    # ETS insert can handle a list of tuples efficiently
    true = :ets.insert(state.table, composite_entries)
    :ok
  rescue
    error -> {:error, error}
  end
end
