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
    cache: %{},
    ref_cache: %{}
  ]

  @type t :: %__MODULE__{
          root_key: String.t(),
          adapter: module(),
          adapter_state: term(),
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

  ## Examples

      iex> PState.new("track:550e8400-e29b-41d4-a716-446655440000",
      ...>   adapter: PState.Adapters.ETS,
      ...>   adapter_opts: [table_name: :my_pstate]
      ...> )
      %PState{root_key: "track:550e8400-...", ...}

  ## Errors

  Raises if:
  - `:adapter` option is not provided
  - Adapter initialization fails

  """
  @spec new(String.t(), keyword()) :: t()
  def new(root_key, opts \\ []) when is_binary(root_key) do
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case adapter.init(adapter_opts) do
      {:ok, adapter_state} ->
        %__MODULE__{
          root_key: root_key,
          adapter: adapter,
          adapter_state: adapter_state,
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
            # Resolve ref using the same visited set (cycle detection happens in fetch_with_visited)
            case fetch_with_visited(pstate, ref_key, visited) do
              {:ok, resolved} -> resolved
              :error -> v
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
end
