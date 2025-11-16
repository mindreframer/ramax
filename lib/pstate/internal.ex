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
