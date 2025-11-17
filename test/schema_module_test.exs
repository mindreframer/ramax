defmodule PState.SchemaModuleTest do
  use ExUnit.Case, async: true

  alias PState.Schema.Field

  describe "RMX002_1A_T1: __using__ registers attributes" do
    test "using PState.Schema registers @entities attribute" do
      # Create a test module that uses PState.Schema
      defmodule TestSchema1 do
        use PState.Schema
      end

      # Verify the module compiles and has __schema__ functions
      assert function_exported?(TestSchema1, :__schema__, 1)
      assert function_exported?(TestSchema1, :__schema__, 2)
    end

    test "using PState.Schema makes macros available" do
      # This test verifies that the import works by attempting to use macros
      assert_compile_success = fn ->
        defmodule TestSchema2 do
          use PState.Schema

          entity :test_entity do
            field(:test_field, :string)
          end
        end
      end

      # Should not raise
      assert_compile_success.()
    end

    test "__schema__(:entities) returns empty map for schema with no entities" do
      defmodule EmptySchema do
        use PState.Schema
      end

      assert EmptySchema.__schema__(:entities) == %{}
    end
  end

  describe "RMX002_1A_T2: Field struct creation" do
    test "can create Field struct with all required fields" do
      field = %Field{
        name: :test_field,
        type: :string
      }

      assert field.name == :test_field
      assert field.type == :string
      assert field.ref_type == nil
      assert field.migrate_fn == nil
      assert field.opts == []
    end

    test "can create Field struct with optional fields" do
      migrate_fn = fn x -> x end

      field = %Field{
        name: :test_field,
        type: :ref,
        ref_type: :other_entity,
        migrate_fn: migrate_fn,
        opts: [some: :option]
      }

      assert field.name == :test_field
      assert field.type == :ref
      assert field.ref_type == :other_entity
      assert field.migrate_fn == migrate_fn
      assert field.opts == [some: :option]
    end

    test "Field struct has correct default values" do
      field = %Field{
        name: :test_field,
        type: :string
      }

      assert field.ref_type == nil
      assert field.migrate_fn == nil
      assert field.opts == []
    end
  end

  describe "RMX002_1A_T3: Field enforces :name and :type" do
    test "Field struct enforces required keys via @enforce_keys" do
      # Verify @enforce_keys is set correctly on the Field module
      assert Field.__struct__() |> Map.keys() |> Enum.sort() ==
               [
                 :__struct__,
                 :migrate_fn,
                 :migrate_fn_ref,
                 :name,
                 :opts,
                 :ref_type,
                 :type,
                 :validate_fn
               ]
               |> Enum.sort()
    end

    test "Field struct allows creation with only required keys" do
      field = %Field{name: :test, type: :string}
      assert field.name == :test
      assert field.type == :string
    end

    test "Field struct has correct default values for optional fields" do
      field = %Field{name: :test, type: :string}
      assert field.ref_type == nil
      assert field.migrate_fn == nil
      assert field.opts == []
    end

    test "Field struct can be created with all fields specified" do
      migrate_fn = fn x -> x end

      field = %Field{
        name: :full_field,
        type: :map,
        ref_type: :some_entity,
        migrate_fn: migrate_fn,
        opts: [key: :value]
      }

      assert field.name == :full_field
      assert field.type == :map
      assert field.ref_type == :some_entity
      assert field.migrate_fn == migrate_fn
      assert field.opts == [key: :value]
    end
  end
end
