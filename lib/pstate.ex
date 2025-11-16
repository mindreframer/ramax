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
end
