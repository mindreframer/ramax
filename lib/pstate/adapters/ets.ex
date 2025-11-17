defmodule PState.Adapters.ETS do
  @moduledoc """
  ETS-based storage adapter for PState.

  This adapter uses Erlang's ETS (Erlang Term Storage) for in-memory
  key-value storage. It's suitable for development, testing, and single-node
  applications where persistence is not required.

  ## Features

  - Fast in-memory storage
  - Read concurrency enabled
  - Public table access
  - Automatic cleanup on process termination

  ## Options

  - `:table_name` - Name of the ETS table (default: `:pstate_ets`)

  ## Examples

      iex> {:ok, state} = PState.Adapters.ETS.init(table_name: :my_table)
      {:ok, %{table: #Reference<...>}}

      iex> PState.Adapters.ETS.put(state, "key", "value")
      :ok

      iex> PState.Adapters.ETS.get(state, "key")
      {:ok, "value"}
  """

  @behaviour PState.Adapter

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, :pstate_ets)

    # Create ETS table with read concurrency for better performance
    table =
      :ets.new(table_name, [
        :set,
        :public,
        {:read_concurrency, true}
      ])

    {:ok, %{table: table}}
  rescue
    error -> {:error, error}
  end

  @impl true
  def get(state, key) do
    case :ets.lookup(state.table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:ok, nil}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def put(state, key, value) do
    true = :ets.insert(state.table, {key, value})
    :ok
  rescue
    error -> {:error, error}
  end

  @impl true
  def delete(state, key) do
    true = :ets.delete(state.table, key)
    :ok
  rescue
    error -> {:error, error}
  end

  @impl true
  def scan(state, prefix, _opts) do
    # Use match to get all entries
    matches = :ets.match(state.table, {:"$1", :"$2"})

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
  def multi_get(state, keys) when is_list(keys) do
    results =
      keys
      |> Enum.reduce(%{}, fn key, acc ->
        case :ets.lookup(state.table, key) do
          [{^key, value}] -> Map.put(acc, key, value)
          [] -> acc
        end
      end)

    {:ok, results}
  rescue
    error -> {:error, error}
  end

  @impl true
  def multi_put(state, entries) when is_list(entries) do
    # ETS insert can handle a list of tuples efficiently
    true = :ets.insert(state.table, entries)
    :ok
  rescue
    error -> {:error, error}
  end
end
