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
end
