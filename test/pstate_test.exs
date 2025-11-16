defmodule PStateTest do
  use ExUnit.Case, async: true

  alias PState

  describe "PState struct" do
    test "RMX001_1A_T4: has all required fields" do
      # Create a PState struct with all fields
      pstate = %PState{
        root_key: "track:uuid",
        adapter: PState.Adapters.ETS,
        adapter_state: %{table: :test_table},
        cache: %{},
        ref_cache: %{}
      }

      assert pstate.root_key == "track:uuid"
      assert pstate.adapter == PState.Adapters.ETS
      assert pstate.adapter_state == %{table: :test_table}
      assert pstate.cache == %{}
      assert pstate.ref_cache == %{}
    end

    test "RMX001_1A_T5: enforces required keys" do
      # Should raise when root_key is missing
      assert_raise ArgumentError, fn ->
        struct!(PState, %{
          adapter: PState.Adapters.ETS,
          adapter_state: %{table: :test_table}
        })
      end

      # Should raise when adapter is missing
      assert_raise ArgumentError, fn ->
        struct!(PState, %{
          root_key: "track:uuid",
          adapter_state: %{table: :test_table}
        })
      end

      # Should raise when adapter_state is missing
      assert_raise ArgumentError, fn ->
        struct!(PState, %{
          root_key: "track:uuid",
          adapter: PState.Adapters.ETS
        })
      end
    end

    test "cache defaults to empty map" do
      pstate = %PState{
        root_key: "track:uuid",
        adapter: PState.Adapters.ETS,
        adapter_state: %{table: :test_table}
      }

      assert pstate.cache == %{}
      assert pstate.ref_cache == %{}
    end

    test "allows custom cache values" do
      pstate = %PState{
        root_key: "track:uuid",
        adapter: PState.Adapters.ETS,
        adapter_state: %{table: :test_table},
        cache: %{"key1" => "value1"},
        ref_cache: %{"ref1" => "resolved1"}
      }

      assert pstate.cache == %{"key1" => "value1"}
      assert pstate.ref_cache == %{"ref1" => "resolved1"}
    end
  end

  describe "PState.new/2 (RMX001_3A)" do
    test "RMX001_3A_T1: creates PState with ETS adapter" do
      pstate =
        PState.new("track:550e8400-e29b-41d4-a716-446655440000",
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: :test_pstate_init_1]
        )

      assert %PState{} = pstate
      assert pstate.root_key == "track:550e8400-e29b-41d4-a716-446655440000"
      assert pstate.adapter == PState.Adapters.ETS
      assert is_map(pstate.adapter_state)
      assert Map.has_key?(pstate.adapter_state, :table)
    end

    test "RMX001_3A_T2: initializes empty caches" do
      pstate =
        PState.new("track:uuid",
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: :test_pstate_init_2]
        )

      assert pstate.cache == %{}
      assert pstate.ref_cache == %{}
    end

    test "RMX001_3A_T3: fails with invalid adapter" do
      # Missing adapter option
      assert_raise KeyError, fn ->
        PState.new("track:uuid", adapter_opts: [table_name: :test])
      end
    end
  end
end
