defmodule PState.Adapter do
  @moduledoc """
  Behaviour for pluggable storage backends with space support.

  This defines the minimal interface that storage adapters must implement
  to work with PState. Adapters provide space-scoped key-value operations:
  get, put, delete, and scan.

  All operations require a `space_id` to ensure data isolation between spaces
  (namespaces) in a multi-tenant environment.

  ## Required Callbacks

  - `init/1` - Initialize adapter with options
  - `get/3` - Get value for a key within a space
  - `put/4` - Put value for a key within a space
  - `delete/3` - Delete a key within a space
  - `scan/4` - Scan keys matching a prefix within a space

  ## Optional Callbacks

  - `multi_get/3` - Batch get optimization
  - `multi_put/3` - Batch put optimization

  ## Examples

      defmodule MyAdapter do
        @behaviour PState.Adapter

        @impl true
        def init(opts) do
          # Initialize your storage
          {:ok, state}
        end

        @impl true
        def get(state, space_id, key) do
          # Retrieve value for space_id and key
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
  Get value for a key within a specific space.

  Returns:
  - `{:ok, value}` if key exists
  - `{:ok, nil}` if key does not exist
  - `{:error, reason}` on error

  ## Examples

      iex> MyAdapter.get(state, 1, "base_card:uuid")
      {:ok, %{front: "Hello", back: "Hola"}}

      iex> MyAdapter.get(state, 1, "nonexistent")
      {:ok, nil}
  """
  @callback get(state, space_id :: pos_integer(), key) :: {:ok, value | nil} | {:error, term()}

  @doc """
  Put value for a key within a specific space.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Examples

      iex> MyAdapter.put(state, 1, "base_card:uuid", %{front: "Hello"})
      :ok
  """
  @callback put(state, space_id :: pos_integer(), key, value) :: :ok | {:error, term()}

  @doc """
  Delete a key within a specific space.

  Returns `:ok` on success or `{:error, reason}` on failure.
  Should return `:ok` even if key doesn't exist.

  ## Examples

      iex> MyAdapter.delete(state, 1, "base_card:uuid")
      :ok
  """
  @callback delete(state, space_id :: pos_integer(), key) :: :ok | {:error, term()}

  @doc """
  Scan keys matching a prefix within a specific space.

  Returns a list of `{key, value}` tuples for all keys that start with
  the given prefix.

  ## Examples

      iex> MyAdapter.scan(state, 1, "base_card:", [])
      {:ok, [{"base_card:uuid1", %{...}}, {"base_card:uuid2", %{...}}]}

      iex> MyAdapter.scan(state, 1, "nonexistent:", [])
      {:ok, []}
  """
  @callback scan(state, space_id :: pos_integer(), prefix :: String.t(), opts) ::
              {:ok, [{key, value}]} | {:error, term()}

  @doc """
  Batch get multiple keys within a specific space (optional optimization).

  Returns a map of `key => value` for all found keys.
  Missing keys are not included in the result.

  ## Examples

      iex> MyAdapter.multi_get(state, 1, ["key1", "key2", "key3"])
      {:ok, %{"key1" => value1, "key2" => value2}}
  """
  @callback multi_get(state, space_id :: pos_integer(), [key]) ::
              {:ok, %{key => value}} | {:error, term()}

  @doc """
  Batch put multiple key-value pairs within a specific space (optional optimization).

  ## Examples

      iex> MyAdapter.multi_put(state, 1, [{"key1", val1}, {"key2", val2}])
      :ok
  """
  @callback multi_put(state, space_id :: pos_integer(), [{key, value}]) :: :ok | {:error, term()}

  @doc """
  Close the adapter and release any resources (database connections, file handles, etc.).

  This is optional for in-memory adapters but critical for adapters that hold persistent
  resources like database connections.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Examples

      :ok = MyAdapter.close(state)
  """
  @callback close(state) :: :ok | {:error, term()}

  @optional_callbacks [multi_get: 3, multi_put: 3]
end
