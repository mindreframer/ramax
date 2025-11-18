defmodule PState do
  @moduledoc """
  Lazy-loading persistent state with auto-resolving references and space support.
  Works transparently with RamaxUtils.Value for JSONPath queries.

  PState provides a GunDB-inspired lazy-loading state management system with
  first-class references that resolve automatically on access. All data is
  scoped to a specific space (namespace) for multi-tenant isolation.

  ## Architecture

  - **Cache**: In-memory cache for entities (key → value)
  - **Ref Cache**: Cached reference resolutions
  - **Adapter**: Pluggable storage backend (ETS, SQLite, etc.)
  - **Space**: Namespace for data isolation (multi-tenancy)

  ## Examples

      iex> pstate = PState.new("track:uuid",
      ...>   space_id: 1,
      ...>   adapter: PState.Adapters.ETS,
      ...>   adapter_opts: [table_name: :my_pstate]
      ...> )
      %PState{root_key: "track:uuid", space_id: 1, ...}

  """

  @behaviour Access

  alias PState.{Internal, Ref}

  @enforce_keys [:root_key, :space_id, :adapter, :adapter_state]
  defstruct [
    :root_key,
    :space_id,
    :adapter,
    :adapter_state,
    :schema,
    cache: %{},
    ref_cache: %{}
  ]

  @type t :: %__MODULE__{
          root_key: String.t(),
          space_id: pos_integer(),
          adapter: module(),
          adapter_state: term(),
          schema: module() | nil,
          cache: %{String.t() => term()},
          ref_cache: %{String.t() => term()}
        }

  @doc """
  Create a new PState instance for a specific space.

  Initializes a new PState with the given root key, space_id, and adapter.
  The adapter is initialized with the provided options.

  ## Options

  - `:space_id` - The space ID for multi-tenant isolation (required)
  - `:adapter` - The adapter module to use (required)
  - `:adapter_opts` - Options to pass to the adapter's init/1 callback (default: [])
  - `:schema` - Optional schema module that defines entity structures (default: nil)

  ## Examples

      iex> PState.new("track:550e8400-e29b-41d4-a716-446655440000",
      ...>   space_id: 1,
      ...>   adapter: PState.Adapters.ETS,
      ...>   adapter_opts: [table_name: :my_pstate]
      ...> )
      %PState{root_key: "track:550e8400-...", space_id: 1, ...}

      iex> PState.new("track:550e8400-e29b-41d4-a716-446655440000",
      ...>   space_id: 1,
      ...>   adapter: PState.Adapters.ETS,
      ...>   adapter_opts: [table_name: :my_pstate],
      ...>   schema: MyApp.ContentSchema
      ...> )
      %PState{root_key: "track:550e8400-...", space_id: 1, schema: MyApp.ContentSchema, ...}

  ## Errors

  Raises if:
  - `:space_id` option is not provided
  - `:adapter` option is not provided
  - Adapter initialization fails

  """
  @spec new(String.t(), keyword()) :: t()
  def new(root_key, opts \\ []) when is_binary(root_key) do
    space_id = Keyword.fetch!(opts, :space_id)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    schema = Keyword.get(opts, :schema, nil)

    case adapter.init(adapter_opts) do
      {:ok, adapter_state} ->
        %__MODULE__{
          root_key: root_key,
          space_id: space_id,
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

  @doc """
  Clear all data for a specific space.

  This is useful when rebuilding PState from events, where you want to
  clear only the data for a specific space while preserving data from
  other spaces in a shared table.

  Returns the PState struct with cleared cache.

  ## Examples

      iex> PState.clear_space(pstate)
      %PState{cache: %{}, ref_cache: %{}, ...}
  """
  @spec clear_space(t()) :: t()
  def clear_space(pstate) do
    # Scan all keys for this space
    {:ok, entries} = pstate.adapter.scan(pstate.adapter_state, pstate.space_id, "", [])

    # Delete each key
    Enum.each(entries, fn {key, _value} ->
      pstate.adapter.delete(pstate.adapter_state, pstate.space_id, key)
    end)

    # Return pstate with cleared caches
    %{pstate | cache: %{}, ref_cache: %{}}
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

      # Returns refs as-is (depth: 0)
      iex> pstate["parent:456"]
      %{id: "456", child: %PState.Ref{key: "child:789"}}  # child is a Ref

  """
  @impl Access
  @spec fetch(t(), String.t()) :: {:ok, term()} | :error
  def fetch(pstate, key) when is_binary(key) do
    # Default to depth 0 (no ref resolution) for performance
    # Writing data with put_in uses fetch internally, and we don't want
    # to resolve refs during writes as that's very slow.
    # For reading with ref resolution, use PState.get_resolved/3 explicitly.
    fetch_with_visited(pstate, key, MapSet.new(), 0)
  end

  @doc """
  Fetch value with reference resolution (EXPLICIT API).

  This is the main API for getting resolved data. Unlike the Access protocol
  (`pstate[key]`) which returns raw data with Refs for safety, this function
  explicitly resolves references to the specified depth.

  ## Parameters

  - `pstate` - PState instance
  - `key` - Key to fetch
  - `opts` - Options keyword list
    - `:depth` - Maximum depth for reference resolution (default: `:infinity`)
      - `0` - No resolution, return refs as-is (same as `pstate[key]`)
      - `1` - Resolve only top-level refs
      - `2` - Resolve refs 2 levels deep
      - `:infinity` - Resolve all refs completely

  ## Examples

      # Get card with full resolution (explicit)
      {:ok, card} = PState.get_resolved(pstate, "card:123")
      # => %{id: "123", deck: %{id: "456", cards: %{...}}, ...}

      # Get card with limited resolution
      {:ok, card} = PState.get_resolved(pstate, "card:123", depth: 1)
      # => %{id: "123", deck: %{id: "456", cards: %{...refs...}}, ...}

      # Get card without any resolution (same as pstate["card:123"])
      {:ok, card} = PState.get_resolved(pstate, "card:123", depth: 0)
      # => %{id: "123", deck: %Ref{key: "deck:456"}, ...}

  """
  @spec get_resolved(t(), String.t(), keyword()) :: {:ok, term()} | :error
  def get_resolved(pstate, key, opts \\ [])
      when is_binary(key) and is_list(opts) do
    depth = Keyword.get(opts, :depth, :infinity)
    fetch_with_visited(pstate, key, MapSet.new(), depth)
  end

  @doc """
  Fetch value with limited reference resolution depth.

  **DEPRECATED:** Use `get_resolved/3` instead for clearer intent.

  This function provides the same functionality as `get_resolved/3` but with
  a positional depth parameter instead of options.

  ## Parameters

  - `pstate` - PState instance
  - `key` - Key to fetch
  - `max_depth` - Maximum depth for reference resolution (default: 1)

  ## Examples

      # Use get_resolved instead (preferred):
      {:ok, card} = PState.get_resolved(pstate, "card:123", depth: 1)

      # Old API (still works):
      {:ok, card} = PState.fetch_shallow(pstate, "card:123", 1)

  """
  @spec fetch_shallow(t(), String.t(), non_neg_integer() | :infinity) ::
          {:ok, term()} | :error
  def fetch_shallow(pstate, key, max_depth \\ 1)
      when is_binary(key) and (is_integer(max_depth) or max_depth == :infinity) do
    fetch_with_visited(pstate, key, MapSet.new(), max_depth)
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

  # Recursive fetch with cycle detection and depth limiting
  defp fetch_with_visited(pstate, key, visited, max_depth) do
    # Detect cycles
    if MapSet.member?(visited, key) do
      raise PState.Error, {:circular_ref, MapSet.to_list(visited)}
    end

    # Add current key to visited set
    new_visited = MapSet.put(visited, key)

    # Calculate current depth
    current_depth = MapSet.size(visited)

    # Only emit telemetry for top-level fetch (not recursive refs)
    start_time = System.monotonic_time(:microsecond)
    from_cache? = Map.has_key?(pstate.cache, key)

    # Emit cache hit/miss telemetry
    if current_depth == 0 do
      :telemetry.execute([:pstate, :cache], %{hit?: if(from_cache?, do: 1, else: 0)}, %{
        key: key
      })
    end

    result = Internal.fetch_and_auto_migrate(pstate, key)

    # Emit fetch telemetry only for top-level fetch
    if current_depth == 0 do
      duration = System.monotonic_time(:microsecond) - start_time

      migrated? =
        case result do
          {:ok, _, migrated?} -> migrated?
          _ -> false
        end

      metadata = %{
        key: key,
        migrated?: migrated?,
        from_cache?: from_cache?
      }

      :telemetry.execute([:pstate, :fetch], %{duration: duration}, metadata)
    end

    # Check if we've reached max depth
    depth_exceeded? = max_depth != :infinity and current_depth >= max_depth

    case result do
      {:ok, %Ref{key: ref_key}, _migrated?} ->
        if depth_exceeded? do
          # Return the ref as-is instead of resolving
          {:ok, %Ref{key: ref_key}}
        else
          # Auto-resolve reference recursively
          fetch_with_visited(pstate, ref_key, new_visited, max_depth)
        end

      {:ok, value, _migrated?} when is_map(value) ->
        if depth_exceeded? do
          # Don't resolve nested refs, return as-is
          {:ok, value}
        else
          # Recursively resolve any refs in the map values
          resolved_value = resolve_nested_refs(pstate, value, new_visited, max_depth)
          {:ok, resolved_value}
        end

      {:ok, value, _migrated?} ->
        {:ok, value}

      :error ->
        :error
    end
  end

  # Recursively resolve refs in nested data structures
  defp resolve_nested_refs(pstate, value, visited, max_depth) when is_map(value) do
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
              # Resolve ref using the same visited set and depth limit
              case fetch_with_visited(pstate, ref_key, visited, max_depth) do
                {:ok, resolved} -> resolved
                :error -> v
              end
            end

          nested when is_map(nested) ->
            resolve_nested_refs(pstate, nested, visited, max_depth)

          other ->
            other
        end

      {k, resolved_v}
    end)
  end

  defp resolve_nested_refs(_pstate, value, _visited, _max_depth), do: value

  # Preloading API

  @doc """
  Preload nested data efficiently using batch fetching.

  Fetches all referenced entities in a single batch operation and warms the cache.
  This is useful for avoiding N+1 queries when you know you'll need to access
  multiple related entities.

  ## Path Specifications

  Paths can be specified as:
  - Single atom: `:cards` - preloads all refs in the `cards` field
  - List of atoms: `[:cards, :translations]` - preloads multiple fields
  - Keyword list: `[cards: [:translations]]` - preloads nested paths

  ## Examples

      # Preload all cards for a deck
      pstate = PState.preload(pstate, "base_deck:uuid", [:cards])

      # Preload nested paths
      pstate = PState.preload(pstate, "base_deck:uuid", [cards: [:translations]])

      # Preload multiple fields
      pstate = PState.preload(pstate, "entity:uuid", [:field1, :field2])

  ## Returns

  Returns the updated PState with warmed cache containing all preloaded entities.
  """
  @spec preload(t(), String.t(), keyword() | [atom()]) :: t()
  def preload(pstate, key, paths) when is_binary(key) do
    # Fetch the root entity and ensure it's in cache
    case Internal.fetch_with_cache(pstate, key) do
      {:ok, entity} when is_map(entity) ->
        # Add root entity to cache
        pstate_with_root = put_in(pstate.cache[key], entity)

        # Collect all keys to preload
        keys_to_preload = collect_preload_keys(entity, paths)

        # Fetch all keys in batch
        pstate_with_cache = batch_fetch_and_warm_cache(pstate_with_root, keys_to_preload)

        # Handle nested preloading recursively
        handle_nested_preload(pstate_with_cache, entity, paths)

      {:ok, _non_map} ->
        # Can't preload on non-map values
        pstate

      :error ->
        # Entity doesn't exist, return unchanged
        pstate
    end
  end

  # Collect all ref keys from specified paths
  defp collect_preload_keys(entity, paths) when is_list(paths) do
    paths
    |> Enum.flat_map(fn
      # Simple atom path: :cards
      path when is_atom(path) ->
        extract_ref_keys(Map.get(entity, path))

      # Keyword path: cards: [:translations]
      {path, _nested_paths} when is_atom(path) ->
        extract_ref_keys(Map.get(entity, path))
    end)
    |> Enum.uniq()
  end

  # Extract ref keys from a value
  defp extract_ref_keys(%Ref{key: key}), do: [key]

  defp extract_ref_keys(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.flat_map(&extract_ref_keys/1)
  end

  defp extract_ref_keys(value) when is_list(value) do
    Enum.flat_map(value, &extract_ref_keys/1)
  end

  defp extract_ref_keys(_other), do: []

  # Batch fetch keys and warm cache
  defp batch_fetch_and_warm_cache(pstate, []), do: pstate

  defp batch_fetch_and_warm_cache(pstate, keys) do
    # Use multi_get if adapter supports it
    if function_exported?(pstate.adapter, :multi_get, 3) do
      case pstate.adapter.multi_get(pstate.adapter_state, pstate.space_id, keys) do
        {:ok, results} ->
          # Warm cache with all results
          Enum.reduce(results, pstate, fn {key, encoded_value}, acc_pstate ->
            decoded_value = Internal.decode_value(encoded_value)
            put_in(acc_pstate.cache[key], decoded_value)
          end)

        {:error, _reason} ->
          # On error, fall back to individual fetches
          fallback_individual_fetch(pstate, keys)
      end
    else
      # Adapter doesn't support multi_get, use individual fetches
      fallback_individual_fetch(pstate, keys)
    end
  end

  # Fallback to individual fetches if multi_get not available
  defp fallback_individual_fetch(pstate, keys) do
    Enum.reduce(keys, pstate, fn key, acc_pstate ->
      case Internal.fetch_with_cache(acc_pstate, key) do
        {:ok, value} ->
          put_in(acc_pstate.cache[key], value)

        :error ->
          acc_pstate
      end
    end)
  end

  # Handle nested preloading recursively
  defp handle_nested_preload(pstate, entity, paths) when is_list(paths) do
    # Check if any paths have nested preloading
    nested_paths =
      Enum.filter(paths, fn
        {_path, nested} when is_list(nested) -> true
        _ -> false
      end)

    if Enum.empty?(nested_paths) do
      # No nested preloading needed
      pstate
    else
      # Process nested preloading
      Enum.reduce(nested_paths, pstate, fn {path, nested_specs}, acc_pstate ->
        # Get the field value from the entity (not cache - path is an atom)
        field_value = Map.get(entity, path)

        if field_value do
          # Get all keys from this field
          keys = extract_ref_keys(field_value)

          # Recursively preload nested paths for each key
          Enum.reduce(keys, acc_pstate, fn key, inner_pstate ->
            preload(inner_pstate, key, nested_specs)
          end)
        else
          acc_pstate
        end
      end)
    end
  end

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

    # Add child ref to parent collection using RamaxUtils.Value.insert
    # This ensures nested structure is created properly
    alias RamaxUtils.Value

    parent_collection_path = "#{parent_key}.#{parent_collection}.#{entity_id}"
    Value.insert(pstate, parent_collection_path, Ref.new(entity_key))
  end
end
