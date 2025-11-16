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
end
