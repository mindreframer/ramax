defmodule PState.Adapter do
  @moduledoc """
  Behaviour for pluggable storage backends.

  This defines the minimal interface that storage adapters must implement
  to work with PState. Adapters provide basic key-value operations:
  get, put, delete, and scan.

  ## Required Callbacks

  - `init/1` - Initialize adapter with options
  - `get/2` - Get value for a key
  - `put/3` - Put value for a key
  - `delete/2` - Delete a key
  - `scan/3` - Scan keys matching a prefix

  ## Optional Callbacks

  - `multi_get/2` - Batch get optimization
  - `multi_put/2` - Batch put optimization

  ## Examples

      defmodule MyAdapter do
        @behaviour PState.Adapter

        @impl true
        def init(opts) do
          # Initialize your storage
          {:ok, state}
        end

        @impl true
        def get(state, key) do
          # Retrieve value
          {:ok, value}
        end

        # ... implement other callbacks
      end
  """

  @type key :: String.t()
  @type value :: term()
  @type state :: term()
  @type opts :: keyword()

  @doc """
  Initialize adapter with options.

  Returns `{:ok, state}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> MyAdapter.init(table_name: :my_table)
      {:ok, %{table: #Reference<...>}}
  """
  @callback init(opts) :: {:ok, state} | {:error, term()}

  @doc """
  Get value for a key.

  Returns:
  - `{:ok, value}` if key exists
  - `{:ok, nil}` if key does not exist
  - `{:error, reason}` on error

  ## Examples

      iex> MyAdapter.get(state, "base_card:uuid")
      {:ok, %{front: "Hello", back: "Hola"}}

      iex> MyAdapter.get(state, "nonexistent")
      {:ok, nil}
  """
  @callback get(state, key) :: {:ok, value | nil} | {:error, term()}

  @doc """
  Put value for a key.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Examples

      iex> MyAdapter.put(state, "base_card:uuid", %{front: "Hello"})
      :ok
  """
  @callback put(state, key, value) :: :ok | {:error, term()}

  @doc """
  Delete a key.

  Returns `:ok` on success or `{:error, reason}` on failure.
  Should return `:ok` even if key doesn't exist.

  ## Examples

      iex> MyAdapter.delete(state, "base_card:uuid")
      :ok
  """
  @callback delete(state, key) :: :ok | {:error, term()}

  @doc """
  Scan keys matching a prefix.

  Returns a list of `{key, value}` tuples for all keys that start with
  the given prefix.

  ## Examples

      iex> MyAdapter.scan(state, "base_card:", [])
      {:ok, [{"base_card:uuid1", %{...}}, {"base_card:uuid2", %{...}}]}

      iex> MyAdapter.scan(state, "nonexistent:", [])
      {:ok, []}
  """
  @callback scan(state, prefix :: String.t(), opts) ::
              {:ok, [{key, value}]} | {:error, term()}

  @doc """
  Batch get multiple keys (optional optimization).

  Returns a map of `key => value` for all found keys.
  Missing keys are not included in the result.

  ## Examples

      iex> MyAdapter.multi_get(state, ["key1", "key2", "key3"])
      {:ok, %{"key1" => value1, "key2" => value2}}
  """
  @callback multi_get(state, [key]) :: {:ok, %{key => value}} | {:error, term()}

  @doc """
  Batch put multiple key-value pairs (optional optimization).

  ## Examples

      iex> MyAdapter.multi_put(state, [{"key1", val1}, {"key2", val2}])
      :ok
  """
  @callback multi_put(state, [{key, value}]) :: :ok | {:error, term()}

  @optional_callbacks [multi_get: 2, multi_put: 2]
end
