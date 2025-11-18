defmodule PState.SpaceTest do
  use ExUnit.Case, async: true

  alias PState

  describe "RMX007_5A: PState with space support" do
    test "RMX007_5_T6: PState.new requires space_id" do
      # Should raise when space_id is missing
      assert_raise KeyError, fn ->
        PState.new("track:uuid",
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: :test_pstate]
        )
      end
    end

    test "RMX007_5_T7: PState.new creates PState with space_id" do
      pstate =
        PState.new("track:uuid",
          space_id: 1,
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: :test_pstate_space]
        )

      assert pstate.space_id == 1
      assert pstate.root_key == "track:uuid"
      assert pstate.adapter == PState.Adapters.ETS
    end

    test "RMX007_5_T8: PState operations use space_id correctly" do
      pstate1 =
        PState.new("root:1",
          space_id: 1,
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: :test_pstate_ops_1]
        )

      pstate2 =
        PState.new("root:2",
          space_id: 2,
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: :test_pstate_ops_2]
        )

      # Put same key in different space PStates
      pstate1 = put_in(pstate1["entity:123"], %{space: 1, data: "space1"})
      pstate2 = put_in(pstate2["entity:123"], %{space: 2, data: "space2"})

      # Fetch should return space-isolated data
      {:ok, val1} = PState.fetch(pstate1, "entity:123")
      {:ok, val2} = PState.fetch(pstate2, "entity:123")

      assert val1 == %{space: 1, data: "space1"}
      assert val2 == %{space: 2, data: "space2"}
    end

    test "cache is space-aware" do
      # Create two PState instances with different spaces but same adapter table
      table_name = :test_pstate_cache_shared

      pstate1 =
        PState.new("root:1",
          space_id: 1,
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: table_name]
        )

      pstate2 =
        PState.new("root:2",
          space_id: 2,
          adapter: PState.Adapters.ETS,
          adapter_opts: [table_name: table_name]
        )

      # Write to space 1
      pstate1 = put_in(pstate1["key"], %{value: "space1"})

      # Write to space 2
      pstate2 = put_in(pstate2["key"], %{value: "space2"})

      # Each PState should have its own cached value
      assert pstate1.cache["key"] == %{value: "space1"}
      assert pstate2.cache["key"] == %{value: "space2"}

      # Fetch should return correct space-isolated values
      {:ok, val1} = PState.fetch(pstate1, "key")
      {:ok, val2} = PState.fetch(pstate2, "key")

      assert val1 == %{value: "space1"}
      assert val2 == %{value: "space2"}
    end

    test "struct enforces space_id field" do
      # Should raise when space_id is missing from struct
      assert_raise ArgumentError, fn ->
        struct!(PState, %{
          root_key: "track:uuid",
          adapter: PState.Adapters.ETS,
          adapter_state: %{table: :test_table}
        })
      end
    end
  end
end
