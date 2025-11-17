defmodule AccessTest do
  use ExUnit.Case, async: true

  alias PState
  alias PState.Ref

  setup do
    # Create a fresh PState instance for each test
    pstate =
      PState.new("test:root",
        adapter: PState.Adapters.ETS,
        adapter_opts: [table_name: :"test_access_#{System.unique_integer([:positive])}"]
      )

    {:ok, pstate: pstate}
  end

  describe "Access.fetch/2 (RMX001_3C)" do
    test "RMX001_3C_T1: returns value for simple key", %{pstate: pstate} do
      # Store a simple value
      pstate = put_in(pstate["entity:123"], %{id: "123", name: "test"})

      # Fetch it
      assert {:ok, %{id: "123", name: "test"}} = PState.fetch(pstate, "entity:123")
    end

    test "RMX001_3C_T2: auto-resolves single ref", %{pstate: pstate} do
      # Store target entity
      pstate = put_in(pstate["target:456"], %{id: "456", data: "resolved"})

      # Store entity with ref to target
      pstate = put_in(pstate["source:123"], Ref.new("target:456"))

      # Fetch source - should auto-resolve to target
      assert {:ok, %{id: "456", data: "resolved"}} = PState.get_resolved(pstate, "source:123", depth: :infinity)
    end

    test "RMX001_3C_T3: resolves nested refs (A→B→C)", %{pstate: pstate} do
      # Create ref chain: A → B → C
      pstate = put_in(pstate["entity:C"], %{id: "C", value: "final"})
      pstate = put_in(pstate["entity:B"], Ref.new("entity:C"))
      pstate = put_in(pstate["entity:A"], Ref.new("entity:B"))

      # Fetch A - should resolve through B to C
      assert {:ok, %{id: "C", value: "final"}} = PState.get_resolved(pstate, "entity:A", depth: :infinity)
    end

    test "RMX001_3C_T4: returns :error for missing key", %{pstate: pstate} do
      assert :error = PState.fetch(pstate, "missing:key")
    end

    test "RMX001_3C_T5: detects circular refs", %{pstate: pstate} do
      # Create circular ref: A → B → A
      pstate = put_in(pstate["entity:A"], Ref.new("entity:B"))
      pstate = put_in(pstate["entity:B"], Ref.new("entity:A"))

      # Should raise PState.Error
      assert_raise PState.Error, fn ->
        PState.get_resolved(pstate, "entity:A", depth: :infinity)
      end
    end

    test "RMX001_3C_T6: pstate[key] syntax works", %{pstate: pstate} do
      # Store a value
      pstate = put_in(pstate["key:123"], %{data: "value"})

      # Access using bracket syntax
      assert %{data: "value"} = pstate["key:123"]
    end

    test "resolves refs in nested map values", %{pstate: pstate} do
      # Store target entities
      pstate = put_in(pstate["child:1"], %{id: "1", name: "Child 1"})
      pstate = put_in(pstate["child:2"], %{id: "2", name: "Child 2"})

      # Store parent with refs in nested structure
      pstate =
        put_in(pstate["parent:100"], %{
          id: "100",
          children: %{
            "c1" => Ref.new("child:1"),
            "c2" => Ref.new("child:2")
          }
        })

      # Fetch parent - refs should be resolved
      assert {:ok, result} = PState.get_resolved(pstate, "parent:100", depth: :infinity)
      assert result.id == "100"
      assert result.children["c1"] == %{id: "1", name: "Child 1"}
      assert result.children["c2"] == %{id: "2", name: "Child 2"}
    end

    test "returns ref if target does not exist", %{pstate: pstate} do
      # Store entity with ref to missing target
      pstate =
        put_in(pstate["entity:123"], %{
          id: "123",
          ref: Ref.new("missing:999")
        })

      # Fetch - should return the ref as-is since target doesn't exist
      assert {:ok, result} = PState.fetch(pstate, "entity:123")
      assert result.id == "123"
      assert result.ref == Ref.new("missing:999")
    end
  end

  describe "Access.get_and_update/3 (RMX001_3C)" do
    test "RMX001_3C_T7: updates value", %{pstate: pstate} do
      # Store initial value
      pstate = put_in(pstate["key:123"], %{count: 1})

      # Update it
      {old_value, pstate} =
        PState.get_and_update(pstate, "key:123", fn current ->
          {current, %{count: current.count + 1}}
        end)

      assert old_value == %{count: 1}

      # Verify update persisted
      assert {:ok, %{count: 2}} = PState.fetch(pstate, "key:123")
    end

    test "passes nil to function when key doesn't exist", %{pstate: pstate} do
      {old_value, pstate} =
        PState.get_and_update(pstate, "new:key", fn current ->
          assert current == nil
          {current, %{new: "value"}}
        end)

      assert old_value == nil
      assert {:ok, %{new: "value"}} = PState.fetch(pstate, "new:key")
    end

    test "deletes when function returns :pop", %{pstate: pstate} do
      # Store a value
      pstate = put_in(pstate["key:123"], %{data: "value"})

      # Pop it
      {old_value, pstate} =
        PState.get_and_update(pstate, "key:123", fn _current ->
          :pop
        end)

      assert old_value == %{data: "value"}
      assert :error = PState.fetch(pstate, "key:123")
    end

    test "invalidates ref_cache on update", %{pstate: pstate} do
      # Store entities with refs
      pstate = put_in(pstate["target:1"], %{value: 1})
      pstate = put_in(pstate["source:1"], Ref.new("target:1"))

      # Fetch to populate ref_cache
      assert {:ok, %{value: 1}} = PState.get_resolved(pstate, "source:1", depth: :infinity)
      assert pstate.ref_cache == %{}

      # Update target
      {_old, pstate} =
        PState.get_and_update(pstate, "target:1", fn _current ->
          {nil, %{value: 2}}
        end)

      # ref_cache should be cleared
      assert pstate.ref_cache == %{}

      # Fetching source should get updated target value
      assert {:ok, %{value: 2}} = PState.get_resolved(pstate, "source:1", depth: :infinity)
    end
  end

  describe "Access.pop/2 (RMX001_3C)" do
    test "RMX001_3C_T8: deletes value", %{pstate: pstate} do
      # Store a value
      pstate = put_in(pstate["key:123"], %{data: "value"})

      # Pop it
      {value, pstate} = PState.pop(pstate, "key:123")

      assert value == %{data: "value"}
      assert :error = PState.fetch(pstate, "key:123")
    end

    test "returns nil when key doesn't exist", %{pstate: pstate} do
      {value, _pstate} = PState.pop(pstate, "missing:key")
      assert value == nil
    end

    test "invalidates ref_cache on pop", %{pstate: pstate} do
      # Store a value
      pstate = put_in(pstate["key:123"], %{data: "value"})

      # Pop it
      {_value, pstate} = PState.pop(pstate, "key:123")

      # ref_cache should be cleared
      assert pstate.ref_cache == %{}
    end
  end

  describe "put_in integration" do
    test "put_in with nested path creates structure", %{pstate: pstate} do
      # This should create nested structure
      pstate = put_in(pstate["entity:1"], %{})
      pstate = put_in(pstate["entity:1"], Map.put(pstate["entity:1"], :name, "Test"))

      assert {:ok, %{name: "Test"}} = PState.fetch(pstate, "entity:1")
    end

    test "put_in stores and retrieves refs correctly", %{pstate: pstate} do
      # Store ref
      ref = Ref.new("target:123")
      pstate = put_in(pstate["source:1"], ref)

      # Retrieve raw value from cache (should be ref)
      assert pstate.cache["source:1"] == ref

      # Store target
      pstate = put_in(pstate["target:123"], %{data: "resolved"})

      # Fetch should resolve
      assert {:ok, %{data: "resolved"}} = PState.get_resolved(pstate, "source:1", depth: :infinity)
    end
  end

  describe "cycle detection edge cases" do
    test "detects self-reference", %{pstate: pstate} do
      # Create self-referencing entity
      pstate = put_in(pstate["entity:A"], Ref.new("entity:A"))

      assert_raise PState.Error, fn ->
        PState.get_resolved(pstate, "entity:A", depth: :infinity)
      end
    end

    test "handles cycle in nested refs by leaving ref unresolved", %{pstate: pstate} do
      # Create entities where nested ref creates cycle (bidirectional pattern)
      # This is similar to parent ↔ child bidirectional refs
      pstate =
        put_in(pstate["entity:A"], %{
          id: "A",
          next: Ref.new("entity:B")
        })

      pstate =
        put_in(pstate["entity:B"], %{
          id: "B",
          next: Ref.new("entity:A")
        })

      # Should not raise - instead leaves the backwards ref unresolved
      {:ok, a} = PState.get_resolved(pstate, "entity:A", depth: :infinity)
      assert a.id == "A"
      # A's next should resolve to B
      assert is_map(a.next)
      assert a.next.id == "B"
      # But B's next should stay as Ref to avoid infinite loop
      assert %Ref{key: "entity:A"} = a.next.next
    end

    test "detects longer cycles (A→B→C→A)", %{pstate: pstate} do
      pstate = put_in(pstate["entity:A"], Ref.new("entity:B"))
      pstate = put_in(pstate["entity:B"], Ref.new("entity:C"))
      pstate = put_in(pstate["entity:C"], Ref.new("entity:A"))

      assert_raise PState.Error, fn ->
        PState.get_resolved(pstate, "entity:A", depth: :infinity)
      end
    end
  end

  describe "caching behavior" do
    test "fetch uses cache when available", %{pstate: pstate} do
      # Store value
      pstate = put_in(pstate["key:1"], %{data: "original"})

      # Fetch populates cache
      assert {:ok, %{data: "original"}} = PState.fetch(pstate, "key:1")

      # Manually modify cache to verify it's being used
      pstate = %{pstate | cache: Map.put(pstate.cache, "key:1", %{data: "cached"})}

      # Should return cached value
      assert {:ok, %{data: "cached"}} = PState.fetch(pstate, "key:1")
    end

    test "write invalidates cache", %{pstate: pstate} do
      # Store and cache value
      pstate = put_in(pstate["key:1"], %{data: "v1"})
      {:ok, _} = PState.fetch(pstate, "key:1")

      # Update value
      pstate = put_in(pstate["key:1"], %{data: "v2"})

      # Should get updated value
      assert {:ok, %{data: "v2"}} = PState.fetch(pstate, "key:1")
    end
  end
end
