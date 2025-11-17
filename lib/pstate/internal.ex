defmodule PState.Internal do
  @moduledoc """
  Internal implementation details for PState.

  This module contains cache management, encoding/decoding,
  and other internal utilities used by PState.

  This module is not part of the public API and may change without notice.
  """

  alias PState.Ref

  @doc """
  Fetch value with cache support.

  Checks the cache first, then falls back to the adapter on cache miss.
  Updates the cache when fetching from the adapter.

  Returns `{:ok, value}` if found, `:error` if not found.

  ## Examples

      iex> PState.Internal.fetch_with_cache(pstate, "key:123")
      {:ok, %{id: "123", name: "test"}}

      iex> PState.Internal.fetch_with_cache(pstate, "missing:key")
      :error
  """
  @spec fetch_with_cache(PState.t(), String.t()) :: {:ok, term()} | :error
  def fetch_with_cache(%PState{} = pstate, key) when is_binary(key) do
    case Map.fetch(pstate.cache, key) do
      {:ok, value} ->
        # Cache hit
        {:ok, value}

      :error ->
        # Cache miss - fetch from adapter
        case pstate.adapter.get(pstate.adapter_state, key) do
          {:ok, nil} ->
            :error

          {:ok, value} ->
            # Decode value and return
            # Note: We cannot update the pstate struct here since this is a fetch operation
            # The cache will be updated by the caller if needed
            decoded = decode_value(value)
            {:ok, decoded}

          {:error, _reason} ->
            :error
        end
    end
  end

  @doc """
  Put value and invalidate cache.

  Encodes the value, writes to the adapter, updates the cache,
  and invalidates the ref_cache.

  Returns the updated PState struct.

  ## Examples

      iex> updated_pstate = PState.Internal.put_and_invalidate(pstate, "key:123", %{data: "value"})
      %PState{cache: %{"key:123" => %{data: "value"}}, ref_cache: %{}}
  """
  @spec put_and_invalidate(PState.t(), String.t(), term()) :: PState.t()
  def put_and_invalidate(%PState{} = pstate, key, value) when is_binary(key) do
    # Encode value for storage
    encoded = encode_value(value)

    # Write to adapter
    :ok = pstate.adapter.put(pstate.adapter_state, key, encoded)

    # Update cache and invalidate ref_cache
    pstate
    |> put_in([Access.key!(:cache), key], value)
    |> invalidate_ref_cache(key)
  end

  @doc """
  Delete key and invalidate cache.

  Deletes from the adapter, removes from cache, and invalidates ref_cache.

  Returns the updated PState struct.

  ## Examples

      iex> updated_pstate = PState.Internal.delete_and_invalidate(pstate, "key:123")
      %PState{cache: %{}, ref_cache: %{}}
  """
  @spec delete_and_invalidate(PState.t(), String.t()) :: PState.t()
  def delete_and_invalidate(%PState{} = pstate, key) when is_binary(key) do
    # Delete from adapter
    :ok = pstate.adapter.delete(pstate.adapter_state, key)

    # Remove from cache and invalidate ref_cache
    pstate
    |> update_in([Access.key!(:cache)], &Map.delete(&1, key))
    |> invalidate_ref_cache(key)
  end

  @doc """
  Migrate entity data field-by-field.

  Iterates through field specs and applies migration functions to fields that need migration.
  Returns a tuple of {migrated_data, changed?} where changed? indicates if any field was migrated.

  ## Examples

      iex> field_specs = [%PState.Schema.Field{name: :metadata, type: :map, migrate_fn: fn str -> %{notes: str} end}]
      iex> data = %{metadata: "old_string"}
      iex> PState.Internal.migrate_entity(data, field_specs)
      {%{metadata: %{notes: "old_string"}}, true}

      iex> field_specs = [%PState.Schema.Field{name: :front, type: :string, migrate_fn: nil}]
      iex> data = %{front: "hello"}
      iex> PState.Internal.migrate_entity(data, field_specs)
      {%{front: "hello"}, false}
  """
  @spec migrate_entity(map(), [PState.Schema.Field.t()]) :: {map(), boolean()}
  def migrate_entity(data, field_specs) do
    Enum.reduce(field_specs, {data, false}, fn field_spec, {acc_data, changed?} ->
      field_name = field_spec.name
      current_value = Map.get(acc_data, field_name)

      if PState.Migration.needs_migration?(current_value, field_spec) do
        new_value = field_spec.migrate_fn.(current_value)
        {Map.put(acc_data, field_name, new_value), true}
      else
        {acc_data, changed?}
      end
    end)
  end

  @doc """
  Extract entity type from key.

  Splits the key on ":" and returns the entity type as an atom.

  ## Examples

      iex> PState.Internal.extract_entity_type("base_card:abc123")
      :base_card

      iex> PState.Internal.extract_entity_type("host_card:550e8400-e29b-41d4-a716-446655440000")
      :host_card
  """
  @spec extract_entity_type(String.t()) :: atom()
  def extract_entity_type(key) do
    [entity_type, _id] = String.split(key, ":", parts: 2)
    String.to_existing_atom(entity_type)
  end

  # Private helper functions

  @doc false
  defp invalidate_ref_cache(pstate, _key) do
    # Phase 1: Simple - clear entire ref_cache
    # Phase 5 (Epic RMX003): Track reverse deps for granular invalidation
    put_in(pstate.ref_cache, %{})
  end

  @doc false
  defp encode_value(%Ref{} = ref), do: ref

  defp encode_value(value) when is_map(value) do
    # Recursively encode nested refs
    Map.new(value, fn {k, v} -> {k, encode_value(v)} end)
  end

  defp encode_value(value), do: value

  @doc false
  defp decode_value(%Ref{} = ref), do: ref

  defp decode_value(value) when is_map(value) do
    # Recursively decode nested refs
    Map.new(value, fn {k, v} -> {k, decode_value(v)} end)
  end

  defp decode_value(value), do: value
end
