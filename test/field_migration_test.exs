defmodule PState.FieldMigrationTest do
  use ExUnit.Case, async: true

  alias PState.Schema.Field

  describe "RMX002_4A_T1: field with do-block" do
    test "field/3 with do-block creates Field with migrate_fn" do
      defmodule FieldWithDoBlockSchema do
        use PState.Schema

        entity :test_entity do
          field :metadata, :map do
            migrate(fn
              str when is_binary(str) -> %{notes: str}
              map when is_map(map) -> map
              nil -> %{}
            end)
          end
        end
      end

      fields = FieldWithDoBlockSchema.__schema__(:fields, :test_entity)
      assert length(fields) == 1

      field = List.first(fields)
      assert %Field{} = field
      assert field.name == :metadata
      assert field.type == :map
      assert field.migrate_fn != nil
      assert is_function(field.migrate_fn, 1)
    end

    test "field/3 with do-block sets opts to empty list" do
      defmodule FieldWithDoBlockNoOptsSchema do
        use PState.Schema

        entity :test_entity do
          field :data, :map do
            migrate(fn x -> x end)
          end
        end
      end

      fields = FieldWithDoBlockNoOptsSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      assert field.opts == []
    end

    test "multiple fields can have migration functions" do
      defmodule MultiFieldWithMigrationSchema do
        use PState.Schema

        entity :test_entity do
          field :field1, :map do
            migrate(fn x -> {:field1, x} end)
          end

          field :field2, :string do
            migrate(fn x -> "field2: #{x}" end)
          end
        end
      end

      fields = MultiFieldWithMigrationSchema.__schema__(:fields, :test_entity)
      assert length(fields) == 2

      field1 = Enum.find(fields, fn f -> f.name == :field1 end)
      field2 = Enum.find(fields, fn f -> f.name == :field2 end)

      assert field1.migrate_fn != nil
      assert field2.migrate_fn != nil
      assert is_function(field1.migrate_fn, 1)
      assert is_function(field2.migrate_fn, 1)
    end
  end

  describe "RMX002_4A_T2: migrate_fn is callable" do
    test "stored migrate_fn can be called" do
      defmodule CallableMigrateFnSchema do
        use PState.Schema

        entity :test_entity do
          field :value, :integer do
            migrate(fn x -> x * 2 end)
          end
        end
      end

      fields = CallableMigrateFnSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      # The migrate_fn should be callable
      assert is_function(field.migrate_fn, 1)
      result = field.migrate_fn.(5)
      assert result == 10
    end

    test "migrate_fn can be called multiple times" do
      defmodule ReusableMigrateFnSchema do
        use PState.Schema

        entity :test_entity do
          field :counter, :integer do
            migrate(fn x -> x + 1 end)
          end
        end
      end

      fields = ReusableMigrateFnSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      # Call it multiple times
      assert field.migrate_fn.(0) == 1
      assert field.migrate_fn.(5) == 6
      assert field.migrate_fn.(10) == 11
    end
  end

  describe "RMX002_4A_T3: migrate_fn receives value" do
    test "migrate_fn receives and processes input value" do
      defmodule ReceivesValueSchema do
        use PState.Schema

        entity :test_entity do
          field :data, :map do
            migrate(fn
              input when is_binary(input) -> %{value: input, type: :string}
              input when is_integer(input) -> %{value: input, type: :integer}
              input -> %{value: input, type: :unknown}
            end)
          end
        end
      end

      fields = ReceivesValueSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      assert field.migrate_fn.("hello") == %{value: "hello", type: :string}
      assert field.migrate_fn.(42) == %{value: 42, type: :integer}
      assert field.migrate_fn.([1, 2, 3]) == %{value: [1, 2, 3], type: :unknown}
    end

    test "migrate_fn with pattern matching on input" do
      defmodule PatternMatchingSchema do
        use PState.Schema

        entity :test_entity do
          field :metadata, :map do
            migrate(fn
              str when is_binary(str) -> %{notes: str}
              map when is_map(map) -> map
              nil -> %{}
            end)
          end
        end
      end

      fields = PatternMatchingSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      # Test pattern matching
      assert field.migrate_fn.("old string") == %{notes: "old string"}
      assert field.migrate_fn.(%{key: "value"}) == %{key: "value"}
      assert field.migrate_fn.(nil) == %{}
    end
  end

  describe "RMX002_4A_T4: migrate_fn transforms value" do
    test "migrate_fn transforms string to map" do
      defmodule StringToMapSchema do
        use PState.Schema

        entity :test_entity do
          field :metadata, :map do
            migrate(fn
              str when is_binary(str) -> %{notes: str}
              map when is_map(map) -> map
            end)
          end
        end
      end

      fields = StringToMapSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      # Old format: string
      result = field.migrate_fn.("legacy data")
      assert result == %{notes: "legacy data"}

      # Current format: map
      result = field.migrate_fn.(%{notes: "current", other: "data"})
      assert result == %{notes: "current", other: "data"}
    end

    test "migrate_fn transforms list to map with refs" do
      defmodule ListToMapSchema do
        use PState.Schema

        entity :test_entity do
          field :translations, :map do
            migrate(fn
              ids when is_list(ids) ->
                Map.new(ids, fn id -> {id, PState.Ref.new(:translation, id)} end)

              refs when is_map(refs) ->
                refs

              nil ->
                %{}
            end)
          end
        end
      end

      fields = ListToMapSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      # Old format: list of IDs
      result = field.migrate_fn.(["id1", "id2", "id3"])
      assert is_map(result)
      assert map_size(result) == 3
      assert %PState.Ref{key: "translation:id1"} = result["id1"]
      assert %PState.Ref{key: "translation:id2"} = result["id2"]
      assert %PState.Ref{key: "translation:id3"} = result["id3"]

      # Current format: map of refs
      current_refs = %{
        "a" => PState.Ref.new(:translation, "a"),
        "b" => PState.Ref.new(:translation, "b")
      }

      result = field.migrate_fn.(current_refs)
      assert result == current_refs

      # Nil case
      result = field.migrate_fn.(nil)
      assert result == %{}
    end

    test "migrate_fn performs complex transformation" do
      defmodule ComplexTransformSchema do
        use PState.Schema

        entity :test_entity do
          field :config, :map do
            migrate(fn
              # Version 1: simple string
              str when is_binary(str) ->
                %{version: 1, data: str, migrated: true}

              # Version 2: map without version
              %{data: data} = map when not is_map_key(map, :version) ->
                Map.merge(map, %{version: 2, migrated: true})

              # Version 3: current format
              %{version: _} = map ->
                map
            end)
          end
        end
      end

      fields = ComplexTransformSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      # V1: string
      result = field.migrate_fn.("old config")
      assert result == %{version: 1, data: "old config", migrated: true}

      # V2: map without version
      result = field.migrate_fn.(%{data: "some data", other: "field"})
      assert result.version == 2
      assert result.data == "some data"
      assert result.other == "field"
      assert result.migrated == true

      # V3: current format
      result = field.migrate_fn.(%{version: 3, data: "current"})
      assert result == %{version: 3, data: "current"}
    end
  end

  describe "RMX002_4A_T5: migrate/1 passthrough" do
    test "migrate macro extracts function from do-block" do
      defmodule MigratePassthroughSchema do
        use PState.Schema

        entity :test_entity do
          field :data, :map do
            migrate(fn x -> {:migrated, x} end)
          end
        end
      end

      fields = MigratePassthroughSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      # The migrate macro should passthrough the function
      assert is_function(field.migrate_fn, 1)
      assert field.migrate_fn.("test") == {:migrated, "test"}
    end

    test "migrate macro works with complex function expressions" do
      defmodule ComplexMigrateSchema do
        use PState.Schema

        entity :test_entity do
          field :value, :integer do
            migrate(fn
              x when x < 0 -> 0
              x when x > 100 -> 100
              x -> x
            end)
          end
        end
      end

      fields = ComplexMigrateSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      # Test the migrated function
      assert field.migrate_fn.(-5) == 0
      assert field.migrate_fn.(150) == 100
      assert field.migrate_fn.(50) == 50
    end

    test "migrate macro preserves function clauses" do
      defmodule MultiClauseMigrateSchema do
        use PState.Schema

        entity :test_entity do
          field :status, :string do
            migrate(fn
              :active -> "active"
              :inactive -> "inactive"
              :pending -> "pending"
              other -> "unknown: #{inspect(other)}"
            end)
          end
        end
      end

      fields = MultiClauseMigrateSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      # Test multiple clauses
      assert field.migrate_fn.(:active) == "active"
      assert field.migrate_fn.(:inactive) == "inactive"
      assert field.migrate_fn.(:pending) == "pending"
      assert field.migrate_fn.(:deleted) == "unknown: :deleted"
    end
  end
end
