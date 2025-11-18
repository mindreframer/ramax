defmodule Ramax.Space do
  @moduledoc """
  Space (namespace) management for multi-tenancy.

  Each space provides complete isolation of events and projections within
  a shared database. Spaces enable:

  - Multi-tenancy (one space per tenant)
  - Environment separation (staging/production in same DB)
  - Selective projection rebuilds (rebuild only one space)
  - Independent per-space event sequences

  ## Space Structure

  Each space has:
  - `space_id`: Integer ID (used in data storage for efficiency)
  - `space_name`: Human-readable name (e.g., "crm_acme", "cms_staging")
  - `metadata`: Optional JSON metadata for application use

  ## Usage

      # Create or get existing space
      {:ok, event_store} = EventStore.new(EventStore.Adapters.SQLite, database: "app.db")
      {:ok, space, event_store} = Ramax.Space.get_or_create(event_store, "crm_acme")

      # List all spaces
      {:ok, spaces} = Ramax.Space.list_all(event_store)

      # Find space by name
      {:ok, space} = Ramax.Space.find_by_name(event_store, "crm_acme")

      # Delete space and all its data
      :ok = Ramax.Space.delete(event_store, space.space_id)

  ## References

  - ADR005: Space Support Architecture Decision
  """

  @type t :: %__MODULE__{
          space_id: pos_integer(),
          space_name: String.t(),
          metadata: map() | nil
        }

  defstruct [:space_id, :space_name, :metadata]

  @doc """
  Create or get existing space by name.

  If the space already exists, returns the existing space.
  If the space doesn't exist, creates it with a unique space_id.

  ## Options

  - `:metadata` - Optional metadata map to store with the space

  ## Examples

      {:ok, space, event_store} = Ramax.Space.get_or_create(
        event_store,
        "crm_acme"
      )

      {:ok, space, event_store} = Ramax.Space.get_or_create(
        event_store,
        "crm_acme",
        metadata: %{tenant: "Acme Corp", plan: "enterprise"}
      )
  """
  @spec get_or_create(EventStore.t(), String.t(), keyword()) ::
          {:ok, t(), EventStore.t()} | {:error, term()}
  def get_or_create(%EventStore{} = event_store, space_name, opts \\ [])
      when is_binary(space_name) do
    metadata = Keyword.get(opts, :metadata)

    case find_by_name(event_store, space_name) do
      {:ok, space} ->
        {:ok, space, event_store}

      {:error, :not_found} ->
        case create_space(event_store, space_name, metadata) do
          {:ok, space, event_store} -> {:ok, space, event_store}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Find space by name.

  ## Examples

      {:ok, space} = Ramax.Space.find_by_name(event_store, "crm_acme")
      {:error, :not_found} = Ramax.Space.find_by_name(event_store, "nonexistent")
  """
  @spec find_by_name(EventStore.t(), String.t()) ::
          {:ok, t()} | {:error, :not_found}
  def find_by_name(%EventStore{} = event_store, space_name) when is_binary(space_name) do
    event_store.adapter.get_space_by_name(event_store.adapter_state, space_name)
  end

  @doc """
  Find space by ID.

  ## Examples

      {:ok, space} = Ramax.Space.find_by_id(event_store, 1)
      {:error, :not_found} = Ramax.Space.find_by_id(event_store, 999)
  """
  @spec find_by_id(EventStore.t(), pos_integer()) ::
          {:ok, t()} | {:error, :not_found}
  def find_by_id(%EventStore{} = event_store, space_id) when is_integer(space_id) do
    event_store.adapter.get_space_by_id(event_store.adapter_state, space_id)
  end

  @doc """
  List all spaces ordered by space_id.

  ## Examples

      {:ok, []} = Ramax.Space.list_all(event_store)

      {:ok, spaces} = Ramax.Space.list_all(event_store)
      # => [
      #   %Ramax.Space{space_id: 1, space_name: "crm_acme"},
      #   %Ramax.Space{space_id: 2, space_name: "crm_widgets"}
      # ]
  """
  @spec list_all(EventStore.t()) :: {:ok, [t()]}
  def list_all(%EventStore{} = event_store) do
    event_store.adapter.list_all_spaces(event_store.adapter_state)
  end

  @doc """
  Delete a space and all its data (events, pstate, checkpoints).

  This operation cascades and removes:
  - All events in this space
  - All PState data in this space
  - Space sequence data
  - Projection checkpoints

  ## Examples

      :ok = Ramax.Space.delete(event_store, 1)
  """
  @spec delete(EventStore.t(), pos_integer()) :: :ok | {:error, term()}
  def delete(%EventStore{} = event_store, space_id) when is_integer(space_id) do
    event_store.adapter.delete_space(event_store.adapter_state, space_id)
  end

  # Private helper to create a new space
  defp create_space(event_store, space_name, metadata) do
    case event_store.adapter.insert_space(
           event_store.adapter_state,
           space_name,
           metadata
         ) do
      {:ok, space_id} ->
        space = %__MODULE__{
          space_id: space_id,
          space_name: space_name,
          metadata: metadata
        }

        {:ok, space, event_store}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
