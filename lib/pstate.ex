defmodule PState do
  @moduledoc """
  Lazy-loading persistent state with auto-resolving references.
  Works transparently with Helpers.Value for JSONPath queries.

  PState provides a GunDB-inspired lazy-loading state management system with
  first-class references that resolve automatically on access.

  ## Architecture

  - **Cache**: In-memory cache for entities (key → value)
  - **Ref Cache**: Cached reference resolutions
  - **Adapter**: Pluggable storage backend (ETS, SQLite, etc.)

  ## Examples

      iex> pstate = PState.new("track:uuid",
      ...>   adapter: PState.Adapters.ETS,
      ...>   adapter_opts: [table_name: :my_pstate]
      ...> )
      %PState{root_key: "track:uuid", ...}

  """

  @behaviour Access

  alias PState.{Internal, Ref}

  @enforce_keys [:root_key, :adapter, :adapter_state]
  defstruct [
    :root_key,
    :adapter,
    :adapter_state,
    :schema,
    cache: %{},
    ref_cache: %{}
  ]

  @type t :: %__MODULE__{
          root_key: String.t(),
          adapter: module(),
          adapter_state: term(),
          schema: module() | nil,
          cache: %{String.t() => term()},
          ref_cache: %{String.t() => term()}
        }

  @doc """
  Create a new PState instance.

  Initializes a new PState with the given root key and adapter.
  The adapter is initialized with the provided options.

  ## Options

  - `:adapter` - The adapter module to use (required)
  - `:adapter_opts` - Options to pass to the adapter's init/1 callback (default: [])
  - `:schema` - Optional schema module that defines entity structures (default: nil)

  ## Examples

      iex> PState.new("track:550e8400-e29b-41d4-a716-446655440000",
      ...>   adapter: PState.Adapters.ETS,
      ...>   adapter_opts: [table_name: :my_pstate]
      ...> )
      %PState{root_key: "track:550e8400-...", ...}

      iex> PState.new("track:550e8400-e29b-41d4-a716-446655440000",
      ...>   adapter: PState.Adapters.ETS,
      ...>   adapter_opts: [table_name: :my_pstate],
      ...>   schema: MyApp.ContentSchema
      ...> )
      %PState{root_key: "track:550e8400-...", schema: MyApp.ContentSchema, ...}

  ## Errors

  Raises if:
  - `:adapter` option is not provided
  - Adapter initialization fails

  """
  @spec new(String.t(), keyword()) :: t()
  def new(root_key, opts \\ []) when is_binary(root_key) do
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    schema = Keyword.get(opts, :schema, nil)

    case adapter.init(adapter_opts) do
      {:ok, adapter_state} ->
        %__MODULE__{
          root_key: root_key,
          adapter: adapter,
          adapter_state: adapter_state,
          schema: schema,
          cache: %{},
          ref_cache: %{}
        }

      {:error, reason} ->
        raise "Failed to initialize adapter #{inspect(adapter)}: #{inspect(reason)}"
    end
  end

  # Access behavior implementation

  @doc """
  Fetch value for key, auto-resolving %Ref{} primitives.

  Implements recursive reference resolution with cycle detection.

  Returns `{:ok, value}` if found, `:error` if not found.
  Raises `PState.Error` if circular reference detected.

  ## Examples

      iex> pstate["entity:123"]
      %{id: "123", name: "test"}

      # Auto-resolves refs
      iex> pstate["parent:456"]
      %{id: "456", child: %{id: "789"}}  # child ref auto-resolved

  """
  @impl Access
  @spec fetch(t(), String.t()) :: {:ok, term()} | :error
  def fetch(pstate, key) when is_binary(key) do
    fetch_with_visited(pstate, key, MapSet.new())
  end

  @doc """
  Update value at key.

  The function receives the current value (or nil if not found) and
  returns either `{get_value, new_value}` or `:pop`.

  Returns `{get_value, updated_pstate}`.

  ## Examples

      iex> {old_value, new_pstate} = get_and_update(pstate, "key:123", fn current ->
      ...>   {current, %{updated: true}}
      ...> end)

  """
  @impl Access
  @spec get_and_update(t(), String.t(), (term() -> {term(), term()} | :pop)) ::
          {term(), t()}
  def get_and_update(pstate, key, fun) when is_binary(key) and is_function(fun, 1) do
    current =
      case fetch(pstate, key) do
        {:ok, value} -> value
        :error -> nil
      end

    case fun.(current) do
      {get_value, new_value} ->
        updated_pstate = Internal.put_and_invalidate(pstate, key, new_value)
        {get_value, updated_pstate}

      :pop ->
        updated_pstate = Internal.delete_and_invalidate(pstate, key)
        {current, updated_pstate}
    end
  end

  @doc """
  Pop (delete) value at key.

  Returns `{current_value, updated_pstate}`.

  ## Examples

      iex> {value, new_pstate} = pop(pstate, "key:123")

  """
  @impl Access
  @spec pop(t(), String.t()) :: {term(), t()}
  def pop(pstate, key) when is_binary(key) do
    current =
      case fetch(pstate, key) do
        {:ok, value} -> value
        :error -> nil
      end

    updated_pstate = Internal.delete_and_invalidate(pstate, key)
    {current, updated_pstate}
  end

  # Private helper functions

  # Recursive fetch with cycle detection
  defp fetch_with_visited(pstate, key, visited) do
    # Detect cycles
    if MapSet.member?(visited, key) do
      raise PState.Error, {:circular_ref, MapSet.to_list(visited)}
    end

    # Add current key to visited set
    new_visited = MapSet.put(visited, key)

    case Internal.fetch_with_cache(pstate, key) do
      {:ok, %Ref{key: ref_key}} ->
        # Auto-resolve reference recursively
        fetch_with_visited(pstate, ref_key, new_visited)

      {:ok, value} when is_map(value) ->
        # Recursively resolve any refs in the map values
        resolved_value = resolve_nested_refs(pstate, value, new_visited)
        {:ok, resolved_value}

      {:ok, value} ->
        {:ok, value}

      :error ->
        :error
    end
  end

  # Recursively resolve refs in nested data structures
  defp resolve_nested_refs(pstate, value, visited) when is_map(value) do
    Map.new(value, fn {k, v} ->
      resolved_v =
        case v do
          %Ref{key: ref_key} ->
            # Check if this ref would create a cycle
            # If it's already in visited, leave it as a Ref instead of raising
            # This allows bidirectional references to work
            if MapSet.member?(visited, ref_key) do
              # Leave as Ref - don't resolve to avoid circular resolution
              v
            else
              # Resolve ref using the same visited set
              case fetch_with_visited(pstate, ref_key, visited) do
                {:ok, resolved} -> resolved
                :error -> v
              end
            end

          nested when is_map(nested) ->
            resolve_nested_refs(pstate, nested, visited)

          other ->
            other
        end

      {k, resolved_v}
    end)
  end

  defp resolve_nested_refs(_pstate, value, _visited), do: value

  # Bidirectional references helper

  @doc """
  Create entity with bidirectional references.

  Creates:
  1. Child entity with ref to parent
  2. Adds child ref to parent's collection

  ## Options

  - `:entity` - Tuple of `{entity_type, entity_id}` for the child entity (required)
  - `:data` - Map of data for the child entity (required)
  - `:parent` - Tuple of `{parent_type, parent_id}` for the parent entity (required)
  - `:parent_collection` - Atom for the parent's collection field (default: `:children`)

  ## Examples

      iex> pstate = PState.create_linked(pstate,
      ...>   entity: {:base_card, "7c9e6679-7425-40de-944b-e07fc1f90ae7"},
      ...>   data: %{front: "Hello", back: "Hola"},
      ...>   parent: {:base_deck, "6ba7b810-9dad-11d1-80b4-00c04fd430c8"},
      ...>   parent_collection: :cards
      ...> )

  This creates:
  - Child entity at "base_card:7c9e6679..." with a `base_deck` ref to parent
  - Parent's `cards` collection gets a ref to the child

  """
  @spec create_linked(t(), keyword()) :: t()
  def create_linked(pstate, opts) when is_list(opts) do
    {entity_type, entity_id} = Keyword.fetch!(opts, :entity)
    data = Keyword.fetch!(opts, :data)
    {parent_type, parent_id} = Keyword.fetch!(opts, :parent)
    parent_collection = Keyword.get(opts, :parent_collection, :children)

    entity_key = "#{entity_type}:#{entity_id}"
    parent_key = "#{parent_type}:#{parent_id}"

    # Add parent ref to child data
    child_data = Map.put(data, parent_type, Ref.new(parent_key))

    # Write child entity
    pstate = put_in(pstate[entity_key], child_data)

    # Add child ref to parent collection using Helpers.Value.insert
    # This ensures nested structure is created properly
    alias Helpers.Value

    parent_collection_path = "#{parent_key}.#{parent_collection}.#{entity_id}"
    Value.insert(pstate, parent_collection_path, Ref.new(entity_key))
  end
end
