defmodule PState.FieldMacroTest do
  use ExUnit.Case, async: true

  alias PState.Schema.Field

  describe "RMX002_3A_T1: field/3 creates Field struct" do
    test "field/3 macro creates a Field struct with correct attributes" do
      defmodule BasicFieldSchema do
        use PState.Schema

        entity :test_entity do
          field(:test_field, :string)
        end
      end

      fields = BasicFieldSchema.__schema__(:fields, :test_entity)
      assert length(fields) == 1

      field = List.first(fields)
      assert %Field{} = field
      assert field.name == :test_field
      assert field.type == :string
      assert field.migrate_fn == nil
      assert field.opts == []
    end

    test "field/3 creates Field struct with opts parameter" do
      defmodule FieldWithOptsSchema do
        use PState.Schema

        entity :test_entity do
          field(:configured_field, :string, default: "hello", required: true)
        end
      end

      fields = FieldWithOptsSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      assert field.name == :configured_field
      assert field.type == :string
      assert field.opts == [default: "hello", required: true]
    end

    test "field/3 creates Field struct with empty opts when not provided" do
      defmodule FieldNoOptsSchema do
        use PState.Schema

        entity :test_entity do
          field(:simple_field, :integer)
        end
      end

      fields = FieldNoOptsSchema.__schema__(:fields, :test_entity)
      field = List.first(fields)

      assert field.opts == []
    end
  end

  describe "RMX002_3A_T2: field with :string type" do
    test "field/3 correctly registers field with :string type" do
      defmodule StringFieldSchema do
        use PState.Schema

        entity :article do
          field(:title, :string)
          field(:content, :string)
          field(:author, :string)
        end
      end

      fields = StringFieldSchema.__schema__(:fields, :article)
      assert length(fields) == 3

      # All fields should have :string type
      assert Enum.all?(fields, fn f -> f.type == :string end)
    end

    test "string field has nil migrate_fn by default" do
      defmodule StringFieldDefaultSchema do
        use PState.Schema

        entity :blog_post do
          field(:title, :string)
        end
      end

      fields = StringFieldDefaultSchema.__schema__(:fields, :blog_post)
      field = List.first(fields)

      assert field.type == :string
      assert field.migrate_fn == nil
    end
  end

  describe "RMX002_3A_T3: field with :integer type" do
    test "field/3 correctly registers field with :integer type" do
      defmodule IntegerFieldSchema do
        use PState.Schema

        entity :counter do
          field(:count, :integer)
          field(:total, :integer)
          field(:timestamp, :integer)
        end
      end

      fields = IntegerFieldSchema.__schema__(:fields, :counter)
      assert length(fields) == 3

      # All fields should have :integer type
      assert Enum.all?(fields, fn f -> f.type == :integer end)
    end

    test "integer field has nil migrate_fn by default" do
      defmodule IntegerFieldDefaultSchema do
        use PState.Schema

        entity :metrics do
          field(:count, :integer)
        end
      end

      fields = IntegerFieldDefaultSchema.__schema__(:fields, :metrics)
      field = List.first(fields)

      assert field.type == :integer
      assert field.migrate_fn == nil
    end
  end

  describe "RMX002_3A_T4: field with :map type" do
    test "field/3 correctly registers field with :map type" do
      defmodule MapFieldSchema do
        use PState.Schema

        entity :config do
          field(:settings, :map)
          field(:metadata, :map)
          field(:options, :map)
        end
      end

      fields = MapFieldSchema.__schema__(:fields, :config)
      assert length(fields) == 3

      # All fields should have :map type
      assert Enum.all?(fields, fn f -> f.type == :map end)
    end

    test "map field has nil migrate_fn by default" do
      defmodule MapFieldDefaultSchema do
        use PState.Schema

        entity :user do
          field(:metadata, :map)
        end
      end

      fields = MapFieldDefaultSchema.__schema__(:fields, :user)
      field = List.first(fields)

      assert field.type == :map
      assert field.migrate_fn == nil
    end

    test "map field can have opts" do
      defmodule MapFieldOptsSchema do
        use PState.Schema

        entity :user do
          field(:metadata, :map, default: %{})
        end
      end

      fields = MapFieldOptsSchema.__schema__(:fields, :user)
      field = List.first(fields)

      assert field.type == :map
      assert field.opts == [default: %{}]
    end
  end

  describe "RMX002_3A_T5: multiple fields in entity" do
    test "entity can have multiple fields of different types" do
      defmodule MultiFieldSchema do
        use PState.Schema

        entity :base_card do
          field(:id, :string)
          field(:front, :string)
          field(:back, :string)
          field(:created_at, :integer)
          field(:metadata, :map)
        end
      end

      fields = MultiFieldSchema.__schema__(:fields, :base_card)
      assert length(fields) == 5

      # Verify field names
      field_names = Enum.map(fields, & &1.name)
      assert :id in field_names
      assert :front in field_names
      assert :back in field_names
      assert :created_at in field_names
      assert :metadata in field_names

      # Verify field types
      id_field = Enum.find(fields, fn f -> f.name == :id end)
      assert id_field.type == :string

      created_at_field = Enum.find(fields, fn f -> f.name == :created_at end)
      assert created_at_field.type == :integer

      metadata_field = Enum.find(fields, fn f -> f.name == :metadata end)
      assert metadata_field.type == :map
    end

    test "fields maintain definition order" do
      defmodule FieldOrderSchema do
        use PState.Schema

        entity :ordered do
          field(:first, :string)
          field(:second, :integer)
          field(:third, :map)
          field(:fourth, :string)
        end
      end

      fields = FieldOrderSchema.__schema__(:fields, :ordered)
      field_names = Enum.map(fields, & &1.name)

      # Fields should be in the order they were defined
      assert field_names == [:first, :second, :third, :fourth]
    end

    test "multiple entities each have their own fields" do
      defmodule MultiEntityFieldsSchema do
        use PState.Schema

        entity :card do
          field(:id, :string)
          field(:content, :string)
        end

        entity :deck do
          field(:id, :string)
          field(:name, :string)
          field(:count, :integer)
        end
      end

      card_fields = MultiEntityFieldsSchema.__schema__(:fields, :card)
      deck_fields = MultiEntityFieldsSchema.__schema__(:fields, :deck)

      assert length(card_fields) == 2
      assert length(deck_fields) == 3

      # Verify card fields
      card_field_names = Enum.map(card_fields, & &1.name)
      assert :id in card_field_names
      assert :content in card_field_names
      refute :name in card_field_names
      refute :count in card_field_names

      # Verify deck fields
      deck_field_names = Enum.map(deck_fields, & &1.name)
      assert :id in deck_field_names
      assert :name in deck_field_names
      assert :count in deck_field_names
      refute :content in deck_field_names
    end
  end

  describe "RMX002_3A_T6: __register_field__ adds to list" do
    test "__register_field__ creates new entity entry when entity doesn't exist" do
      defmodule FirstFieldSchema do
        use PState.Schema

        entity :new_entity do
          field(:first_field, :string)
        end
      end

      # Verify entity was created with the field
      fields = FirstFieldSchema.__schema__(:fields, :new_entity)
      assert length(fields) == 1
      assert List.first(fields).name == :first_field
    end

    test "__register_field__ adds to existing entity's field list" do
      defmodule AccumulatingFieldsSchema do
        use PState.Schema

        entity :accumulating do
          field(:field1, :string)
          field(:field2, :integer)
          field(:field3, :map)
        end
      end

      # All fields should be accumulated in the entity
      fields = AccumulatingFieldsSchema.__schema__(:fields, :accumulating)
      assert length(fields) == 3

      field_names = Enum.map(fields, & &1.name)
      assert :field1 in field_names
      assert :field2 in field_names
      assert :field3 in field_names
    end

    test "__register_field__ works across multiple entities" do
      defmodule MultiEntityRegistrationSchema do
        use PState.Schema

        entity :entity_a do
          field(:a_field, :string)
        end

        entity :entity_b do
          field(:b_field, :integer)
        end

        entity :entity_a do
          field(:another_a_field, :map)
        end
      end

      # Each entity should have its fields
      entity_a_fields = MultiEntityRegistrationSchema.__schema__(:fields, :entity_a)
      entity_b_fields = MultiEntityRegistrationSchema.__schema__(:fields, :entity_b)

      # entity_a should have 2 fields (from two separate entity blocks)
      assert length(entity_a_fields) == 2
      a_field_names = Enum.map(entity_a_fields, & &1.name)
      assert :a_field in a_field_names
      assert :another_a_field in a_field_names

      # entity_b should have 1 field
      assert length(entity_b_fields) == 1
      assert List.first(entity_b_fields).name == :b_field
    end

    test "__register_field__ preserves field attributes" do
      defmodule PreserveAttributesSchema do
        use PState.Schema

        entity :test do
          field(:simple, :string)
          field(:with_opts, :integer, default: 0, required: true)
        end
      end

      fields = PreserveAttributesSchema.__schema__(:fields, :test)

      simple_field = Enum.find(fields, fn f -> f.name == :simple end)
      assert simple_field.name == :simple
      assert simple_field.type == :string
      assert simple_field.opts == []
      assert simple_field.migrate_fn == nil

      opts_field = Enum.find(fields, fn f -> f.name == :with_opts end)
      assert opts_field.name == :with_opts
      assert opts_field.type == :integer
      assert opts_field.opts == [default: 0, required: true]
      assert opts_field.migrate_fn == nil
    end
  end
end
