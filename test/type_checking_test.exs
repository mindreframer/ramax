defmodule PState.TypeCheckingTest do
  use ExUnit.Case, async: true

  alias PState.Migration
  alias PState.Ref

  describe "RMX003_1A: type_matches?/2" do
    test "RMX003_1A_T1: type_matches? with nil" do
      # Nil should match any type
      assert Migration.type_matches?(nil, :string)
      assert Migration.type_matches?(nil, :integer)
      assert Migration.type_matches?(nil, :map)
      assert Migration.type_matches?(nil, :list)
      assert Migration.type_matches?(nil, :ref)
      assert Migration.type_matches?(nil, :collection)
    end

    test "RMX003_1A_T2: type_matches? with :string" do
      # String values should match :string type
      assert Migration.type_matches?("hello", :string)
      assert Migration.type_matches?("", :string)
      assert Migration.type_matches?("multi\nline", :string)

      # Non-string values should not match :string type
      refute Migration.type_matches?(42, :string)
      refute Migration.type_matches?(%{}, :string)
      refute Migration.type_matches?([], :string)
    end

    test "RMX003_1A_T3: type_matches? with :integer" do
      # Integer values should match :integer type
      assert Migration.type_matches?(0, :integer)
      assert Migration.type_matches?(42, :integer)
      assert Migration.type_matches?(-100, :integer)

      # Non-integer values should not match :integer type
      refute Migration.type_matches?(42.5, :integer)
      refute Migration.type_matches?("42", :integer)
      refute Migration.type_matches?(%{}, :integer)
    end

    test "RMX003_1A_T4: type_matches? with :map" do
      # Plain map values should match :map type
      assert Migration.type_matches?(%{}, :map)
      assert Migration.type_matches?(%{a: 1, b: 2}, :map)
      assert Migration.type_matches?(%{"key" => "value"}, :map)

      # Structs should NOT match :map type (since is_struct guard)
      refute Migration.type_matches?(%Ref{key: "card:1"}, :map)

      # Non-map values should not match :map type
      refute Migration.type_matches?("map", :map)
      refute Migration.type_matches?([], :map)
      refute Migration.type_matches?(42, :map)
    end

    test "RMX003_1A_T5: type_matches? with :list" do
      # List values should match :list type
      assert Migration.type_matches?([], :list)
      assert Migration.type_matches?([1, 2, 3], :list)
      assert Migration.type_matches?(["a", "b"], :list)
      assert Migration.type_matches?([%{}, %{}], :list)

      # Non-list values should not match :list type
      refute Migration.type_matches?("list", :list)
      refute Migration.type_matches?(%{}, :list)
      refute Migration.type_matches?(42, :list)
    end

    test "RMX003_1A_T6: type_matches? with :ref" do
      # PState.Ref structs should match :ref type
      ref = %Ref{key: "base_card:uuid"}
      assert Migration.type_matches?(ref, :ref)

      ref2 = Ref.new(:base_card, "uuid")
      assert Migration.type_matches?(ref2, :ref)

      # Non-ref values should not match :ref type
      refute Migration.type_matches?("base_card:uuid", :ref)
      refute Migration.type_matches?(%{key: "base_card:uuid"}, :ref)
      refute Migration.type_matches?([], :ref)
    end

    test "RMX003_1A_T7: type_matches? with :collection" do
      # Collections always match (for now)
      assert Migration.type_matches?("anything", :collection)
      assert Migration.type_matches?(42, :collection)
      assert Migration.type_matches?(%{}, :collection)
      assert Migration.type_matches?([], :collection)
      assert Migration.type_matches?(%Ref{key: "card:1"}, :collection)
    end

    test "RMX003_1A_T8: type mismatch (string vs integer)" do
      # String value should not match integer type
      refute Migration.type_matches?("42", :integer)

      # Integer value should not match string type
      refute Migration.type_matches?(42, :string)
    end

    test "RMX003_1A_T9: type mismatch (map vs string)" do
      # Map value should not match string type
      refute Migration.type_matches?(%{notes: "test"}, :string)

      # String value should not match map type
      refute Migration.type_matches?("test", :map)
    end
  end
end
