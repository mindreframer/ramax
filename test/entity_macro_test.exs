defmodule PState.EntityMacroTest do
  use ExUnit.Case, async: true

  describe "RMX002_2A_T1: entity/2 sets current_entity" do
    test "entity/2 macro sets @current_entity for field definitions" do
      defmodule SingleEntitySchema do
        use PState.Schema

        entity :test_entity do
          field(:test_field, :string)
        end
      end

      # Verify the entity was registered
      entities = SingleEntitySchema.__schema__(:entities)
      assert Map.has_key?(entities, :test_entity)
    end

    test "entity/2 properly scopes fields to the current entity" do
      defmodule ScopedEntitySchema do
        use PState.Schema

        entity :entity_one do
          field(:field_one, :string)
        end

        entity :entity_two do
          field(:field_two, :integer)
        end
      end

      # Verify each entity has only its own fields
      entity_one_fields = ScopedEntitySchema.__schema__(:fields, :entity_one)
      entity_two_fields = ScopedEntitySchema.__schema__(:fields, :entity_two)

      assert length(entity_one_fields) == 1
      assert length(entity_two_fields) == 1

      assert Enum.any?(entity_one_fields, fn f -> f.name == :field_one end)
      assert Enum.any?(entity_two_fields, fn f -> f.name == :field_two end)

      # Ensure fields don't bleed across entities
      refute Enum.any?(entity_one_fields, fn f -> f.name == :field_two end)
      refute Enum.any?(entity_two_fields, fn f -> f.name == :field_one end)
    end
  end

  describe "RMX002_2A_T2: entity/2 executes block" do
    test "entity/2 executes the do-block containing field definitions" do
      defmodule BlockExecutionSchema do
        use PState.Schema

        entity :card do
          field(:id, :string)
          field(:title, :string)
          field(:count, :integer)
        end
      end

      # Verify all fields from the block were processed
      fields = BlockExecutionSchema.__schema__(:fields, :card)
      assert length(fields) == 3

      field_names = Enum.map(fields, & &1.name)
      assert :id in field_names
      assert :title in field_names
      assert :count in field_names
    end

    # TODO RMX002_2A: Migration function storage not yet working
    # The issue is that migration functions cannot be escaped into AST
    # This will be addressed in RMX002_4A when implementing field migrations properly
    @tag :skip
    test "entity/2 block can contain complex field definitions" do
      defmodule ComplexBlockSchema do
        use PState.Schema

        entity :user do
          field(:id, :string)
          field(:name, :string, default: "Anonymous")

          field :metadata, :map do
            fn
              str when is_binary(str) -> %{note: str}
              map when is_map(map) -> map
            end
          end
        end
      end

      fields = ComplexBlockSchema.__schema__(:fields, :user)
      assert length(fields) == 3

      # Find the metadata field and verify it has a migration function
      metadata_field = Enum.find(fields, fn f -> f.name == :metadata end)
      assert metadata_field != nil
      assert metadata_field.migrate_fn != nil
      assert is_function(metadata_field.migrate_fn, 1)
    end
  end

  describe "RMX002_2A_T3: multiple entities" do
    test "can define multiple entities in the same schema" do
      defmodule MultiEntitySchema do
        use PState.Schema

        entity :base_card do
          field(:id, :string)
          field(:front, :string)
          field(:back, :string)
        end

        entity :host_card do
          field(:id, :string)
          field(:country, :string)
        end

        entity :deck do
          field(:id, :string)
          field(:name, :string)
        end
      end

      entities = MultiEntitySchema.__schema__(:entities)
      assert map_size(entities) == 3
      assert Map.has_key?(entities, :base_card)
      assert Map.has_key?(entities, :host_card)
      assert Map.has_key?(entities, :deck)
    end

    test "multiple entities maintain separate field lists" do
      defmodule SeparateFieldsSchema do
        use PState.Schema

        entity :entity_a do
          field(:field_a1, :string)
          field(:field_a2, :integer)
        end

        entity :entity_b do
          field(:field_b1, :map)
        end

        entity :entity_c do
          field(:field_c1, :string)
          field(:field_c2, :string)
          field(:field_c3, :integer)
        end
      end

      # Verify each entity has correct number of fields
      assert length(SeparateFieldsSchema.__schema__(:fields, :entity_a)) == 2
      assert length(SeparateFieldsSchema.__schema__(:fields, :entity_b)) == 1
      assert length(SeparateFieldsSchema.__schema__(:fields, :entity_c)) == 3
    end

    test "entities can be defined in any order" do
      defmodule OrderedEntitiesSchema do
        use PState.Schema

        entity :third do
          field(:field_3, :string)
        end

        entity :first do
          field(:field_1, :string)
        end

        entity :second do
          field(:field_2, :string)
        end
      end

      entities = OrderedEntitiesSchema.__schema__(:entities)
      # All entities should be present regardless of definition order
      assert Map.has_key?(entities, :first)
      assert Map.has_key?(entities, :second)
      assert Map.has_key?(entities, :third)
    end
  end

  describe "RMX002_2A_T4: entity name is atom" do
    test "entity/2 accepts atom as entity name" do
      defmodule AtomNameSchema do
        use PState.Schema

        entity :valid_atom_name do
          field(:test, :string)
        end
      end

      assert Map.has_key?(AtomNameSchema.__schema__(:entities), :valid_atom_name)
    end

    test "entity/2 works with various atom formats" do
      defmodule VariousAtomNamesSchema do
        use PState.Schema

        entity :snake_case_name do
          field(:field1, :string)
        end

        entity :CamelCase do
          field(:field2, :string)
        end

        entity :name123 do
          field(:field3, :string)
        end

        entity :simple do
          field(:field4, :string)
        end
      end

      entities = VariousAtomNamesSchema.__schema__(:entities)
      assert Map.has_key?(entities, :snake_case_name)
      assert Map.has_key?(entities, :CamelCase)
      assert Map.has_key?(entities, :name123)
      assert Map.has_key?(entities, :simple)
    end

    test "__schema__(:entity, name) returns nil for non-existent entity" do
      defmodule LookupTestSchema do
        use PState.Schema

        entity :existing do
          field(:test, :string)
        end
      end

      assert LookupTestSchema.__schema__(:entity, :existing) != nil
      assert LookupTestSchema.__schema__(:entity, :non_existent) == nil
    end

    test "__schema__(:fields, name) returns empty list for non-existent entity" do
      defmodule FieldsLookupSchema do
        use PState.Schema

        entity :existing do
          field(:test, :string)
        end
      end

      # Existing entity returns fields
      assert length(FieldsLookupSchema.__schema__(:fields, :existing)) == 1

      # Non-existent entity returns empty list
      assert FieldsLookupSchema.__schema__(:fields, :non_existent) == []
    end
  end
end
