defmodule PState.RefTest do
  use ExUnit.Case, async: true

  alias PState.Ref

  describe "Ref.new/1" do
    test "RMX001_1A_T1: creates ref with key" do
      ref = Ref.new("base_card:550e8400-e29b-41d4-a716-446655440000")

      assert %Ref{key: "base_card:550e8400-e29b-41d4-a716-446655440000"} = ref
      assert ref.key == "base_card:550e8400-e29b-41d4-a716-446655440000"
    end
  end

  describe "Ref.new/2" do
    test "RMX001_1A_T2: builds key from entity_type and id" do
      ref = Ref.new(:base_card, "550e8400-e29b-41d4-a716-446655440000")

      assert %Ref{key: "base_card:550e8400-e29b-41d4-a716-446655440000"} = ref
      assert ref.key == "base_card:550e8400-e29b-41d4-a716-446655440000"
    end

    test "constructs key with correct format" do
      ref = Ref.new(:base_deck, "uuid-123")
      assert ref.key == "base_deck:uuid-123"
    end
  end

  describe "Ref struct" do
    test "RMX001_1A_T3: enforces :key field" do
      # Should raise when key is missing
      assert_raise ArgumentError, fn ->
        struct!(Ref, %{})
      end
    end

    test "allows valid construction" do
      ref = %Ref{key: "test:123"}
      assert ref.key == "test:123"
    end
  end
end
