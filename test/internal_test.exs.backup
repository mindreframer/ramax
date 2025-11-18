defmodule PState.InternalTest do
  use ExUnit.Case, async: true

  alias PState
  alias PState.Adapters.ETS
  alias PState.Internal
  alias PState.Ref

  describe "fetch_with_cache/2" do
    setup do
      pstate = PState.new("test:root", adapter: ETS, adapter_opts: [])
      {:ok, pstate: pstate}
    end

    test "RMX001_3B_T1: returns cached value on cache hit", %{pstate: pstate} do
      # Populate cache directly
      pstate = put_in(pstate.cache["test:key"], %{data: "cached"})

      assert {:ok, %{data: "cached"}} = Internal.fetch_with_cache(pstate, "test:key")
    end

    test "RMX001_3B_T2: fetches from adapter on cache miss", %{pstate: pstate} do
      # Store value in adapter
      :ok = ETS.put(pstate.adapter_state, "test:key", %{data: "from_adapter"})

      assert {:ok, %{data: "from_adapter"}} = Internal.fetch_with_cache(pstate, "test:key")
    end

    test "RMX001_3B_T3: returns :error for missing key", %{pstate: pstate} do
      assert :error = Internal.fetch_with_cache(pstate, "missing:key")
    end

    test "RMX001_3B_T4: decodes nested refs when fetching from adapter", %{pstate: pstate} do
      ref = Ref.new("target:123")

      value = %{
        id: "test",
        ref_field: ref,
        nested: %{ref: ref}
      }

      :ok = ETS.put(pstate.adapter_state, "test:key", value)

      assert {:ok, fetched} = Internal.fetch_with_cache(pstate, "test:key")
      assert %Ref{key: "target:123"} = fetched.ref_field
      assert %Ref{key: "target:123"} = fetched.nested.ref
    end
  end

  describe "put_and_invalidate/3" do
    setup do
      pstate = PState.new("test:root", adapter: ETS, adapter_opts: [])
      {:ok, pstate: pstate}
    end

    test "RMX001_3B_T5: writes value to adapter", %{pstate: pstate} do
      pstate = Internal.put_and_invalidate(pstate, "test:key", %{data: "value"})

      # Verify written to adapter
      assert {:ok, %{data: "value"}} = ETS.get(pstate.adapter_state, "test:key")
    end

    test "RMX001_3B_T6: updates cache with value", %{pstate: pstate} do
      pstate = Internal.put_and_invalidate(pstate, "test:key", %{data: "value"})

      # Verify cache updated
      assert %{data: "value"} = pstate.cache["test:key"]
    end

    test "RMX001_3B_T7: clears ref_cache on write", %{pstate: pstate} do
      # Populate ref_cache
      pstate = put_in(pstate.ref_cache["some:ref"], %{resolved: "data"})

      pstate = Internal.put_and_invalidate(pstate, "test:key", %{data: "value"})

      # Verify ref_cache cleared
      assert pstate.ref_cache == %{}
    end

    test "RMX001_3B_T8: encodes nested refs before writing", %{pstate: pstate} do
      ref = Ref.new("target:123")

      value = %{
        id: "test",
        ref_field: ref,
        nested: %{ref: ref}
      }

      pstate = Internal.put_and_invalidate(pstate, "test:key", value)

      # Verify encoded value in adapter
      assert {:ok, stored} = ETS.get(pstate.adapter_state, "test:key")
      assert %Ref{key: "target:123"} = stored.ref_field
      assert %Ref{key: "target:123"} = stored.nested.ref
    end

    test "RMX001_3B_T9: preserves existing cache entries", %{pstate: pstate} do
      # Add existing cache entry
      pstate = put_in(pstate.cache["existing:key"], %{data: "existing"})

      pstate = Internal.put_and_invalidate(pstate, "new:key", %{data: "new"})

      # Verify existing entry preserved
      assert %{data: "existing"} = pstate.cache["existing:key"]
      assert %{data: "new"} = pstate.cache["new:key"]
    end
  end

  describe "delete_and_invalidate/2" do
    setup do
      pstate = PState.new("test:root", adapter: ETS, adapter_opts: [])
      {:ok, pstate: pstate}
    end

    test "RMX001_3B_T10: removes key from adapter", %{pstate: pstate} do
      # Store value first
      :ok = ETS.put(pstate.adapter_state, "test:key", %{data: "value"})

      pstate = Internal.delete_and_invalidate(pstate, "test:key")

      # Verify removed from adapter
      assert {:ok, nil} = ETS.get(pstate.adapter_state, "test:key")
    end

    test "RMX001_3B_T11: removes key from cache", %{pstate: pstate} do
      # Populate cache
      pstate = put_in(pstate.cache["test:key"], %{data: "cached"})

      pstate = Internal.delete_and_invalidate(pstate, "test:key")

      # Verify removed from cache
      refute Map.has_key?(pstate.cache, "test:key")
    end

    test "RMX001_3B_T12: clears ref_cache on delete", %{pstate: pstate} do
      # Populate ref_cache
      pstate = put_in(pstate.ref_cache["some:ref"], %{resolved: "data"})

      pstate = Internal.delete_and_invalidate(pstate, "test:key")

      # Verify ref_cache cleared
      assert pstate.ref_cache == %{}
    end

    test "RMX001_3B_T13: handles delete of non-existent key gracefully", %{pstate: pstate} do
      # Should not raise error
      pstate = Internal.delete_and_invalidate(pstate, "missing:key")

      assert pstate.cache == %{}
      assert pstate.ref_cache == %{}
    end
  end

  describe "encode_value/1 and decode_value/1" do
    test "RMX001_3B_T14: encode/decode preserve Ref structs" do
      ref = Ref.new("target:123")

      # Test via put_and_invalidate which calls encode_value
      pstate = PState.new("test:root", adapter: ETS, adapter_opts: [])
      pstate = Internal.put_and_invalidate(pstate, "test:key", ref)

      # Test via fetch_with_cache which calls decode_value
      assert {:ok, %Ref{key: "target:123"}} = Internal.fetch_with_cache(pstate, "test:key")
    end

    test "RMX001_3B_T15: encode/decode preserve nested refs in maps" do
      ref1 = Ref.new("target:123")
      ref2 = Ref.new("target:456")

      value = %{
        id: "test",
        ref1: ref1,
        nested: %{
          ref2: ref2,
          deep: %{ref1: ref1}
        }
      }

      pstate = PState.new("test:root", adapter: ETS, adapter_opts: [])
      pstate = Internal.put_and_invalidate(pstate, "test:key", value)

      assert {:ok, decoded} = Internal.fetch_with_cache(pstate, "test:key")
      assert %Ref{key: "target:123"} = decoded.ref1
      assert %Ref{key: "target:456"} = decoded.nested.ref2
      assert %Ref{key: "target:123"} = decoded.nested.deep.ref1
    end

    test "RMX001_3B_T16: encode/decode preserve non-ref values" do
      value = %{
        string: "hello",
        number: 42,
        list: [1, 2, 3],
        map: %{nested: "value"}
      }

      pstate = PState.new("test:root", adapter: ETS, adapter_opts: [])
      pstate = Internal.put_and_invalidate(pstate, "test:key", value)

      assert {:ok, ^value} = Internal.fetch_with_cache(pstate, "test:key")
    end
  end

  describe "cache behavior" do
    test "RMX001_3B_T17: cache hit avoids adapter call" do
      pstate = PState.new("test:root", adapter: ETS, adapter_opts: [])

      # Populate cache
      pstate = put_in(pstate.cache["test:key"], %{data: "cached"})

      # Clear adapter to ensure it's not called
      :ok = ETS.delete(pstate.adapter_state, "test:key")

      # Should return cached value without adapter call
      assert {:ok, %{data: "cached"}} = Internal.fetch_with_cache(pstate, "test:key")
    end

    test "RMX001_3B_T18: multiple puts update cache correctly" do
      pstate = PState.new("test:root", adapter: ETS, adapter_opts: [])

      pstate = Internal.put_and_invalidate(pstate, "test:key", %{version: 1})
      assert %{version: 1} = pstate.cache["test:key"]

      pstate = Internal.put_and_invalidate(pstate, "test:key", %{version: 2})
      assert %{version: 2} = pstate.cache["test:key"]

      # Verify adapter has latest version
      assert {:ok, %{version: 2}} = ETS.get(pstate.adapter_state, "test:key")
    end

    test "RMX001_3B_T19: ref_cache invalidation is complete" do
      pstate = PState.new("test:root", adapter: ETS, adapter_opts: [])

      # Populate ref_cache with multiple entries
      pstate =
        pstate
        |> put_in([Access.key!(:ref_cache), "ref:1"], %{data: "1"})
        |> put_in([Access.key!(:ref_cache), "ref:2"], %{data: "2"})
        |> put_in([Access.key!(:ref_cache), "ref:3"], %{data: "3"})

      # Any write should clear entire ref_cache
      pstate = Internal.put_and_invalidate(pstate, "test:key", %{data: "value"})

      assert pstate.ref_cache == %{}
    end
  end
end
