defmodule SchemaCompilationTest do
  use ExUnit.Case, async: true

  alias PState.Schema.Field

  # RMX002_6A_T1: Test __schema__(:entities) returns map
  describe "__schema__(:entities)" do
    defmodule BasicSchema do
      use PState.Schema

      entity :user do
        field(:id, :string)
        field(:name, :string)
        field(:age, :integer)
      end

      entity :post do
        field(:id, :string)
        field(:title, :string)
        field(:content, :string)
      end
    end

    test "returns a map with all entities" do
      entities = BasicSchema.__schema__(:entities)

      assert is_map(entities)
      assert Map.has_key?(entities, :user)
      assert Map.has_key?(entities, :post)
    end

    test "each entity value is a list of Field structs" do
      entities = BasicSchema.__schema__(:entities)

      user_fields = entities[:user]
      assert is_list(user_fields)
      assert length(user_fields) == 3

      Enum.each(user_fields, fn field ->
        assert %Field{} = field
      end)
    end

    test "entity fields contain correct field names" do
      entities = BasicSchema.__schema__(:entities)

      user_field_names = Enum.map(entities[:user], & &1.name)
      assert :id in user_field_names
      assert :name in user_field_names
      assert :age in user_field_names

      post_field_names = Enum.map(entities[:post], & &1.name)
      assert :id in post_field_names
      assert :title in post_field_names
      assert :content in post_field_names
    end
  end

  # RMX002_6A_T2: Test __schema__(:entity, name) returns fields
  describe "__schema__(:entity, name)" do
    defmodule UserSchema do
      use PState.Schema

      entity :user do
        field(:id, :string)
        field(:email, :string)
        field(:age, :integer)
      end

      entity :admin do
        field(:id, :string)
        field(:level, :integer)
      end
    end

    test "returns field list for existing entity" do
      fields = UserSchema.__schema__(:entity, :user)

      assert is_list(fields)
      assert length(fields) == 3

      Enum.each(fields, fn field ->
        assert %Field{} = field
      end)
    end

    test "returns correct fields for different entities" do
      user_fields = UserSchema.__schema__(:entity, :user)
      admin_fields = UserSchema.__schema__(:entity, :admin)

      user_names = Enum.map(user_fields, & &1.name)
      assert :id in user_names
      assert :email in user_names
      assert :age in user_names

      admin_names = Enum.map(admin_fields, & &1.name)
      assert :id in admin_names
      assert :level in admin_names
      refute :email in admin_names
    end

    test "returns nil for non-existent entity" do
      assert UserSchema.__schema__(:entity, :nonexistent) == nil
    end
  end

  # RMX002_6A_T3: Test __schema__(:fields, name) returns list
  describe "__schema__(:fields, entity_name)" do
    defmodule ProductSchema do
      use PState.Schema

      entity :product do
        field(:id, :string)
        field(:name, :string)
        field(:price, :integer)
        field(:metadata, :map)
      end
    end

    test "returns field list for existing entity" do
      fields = ProductSchema.__schema__(:fields, :product)

      assert is_list(fields)
      assert length(fields) == 4
    end

    test "returns empty list for non-existent entity" do
      fields = ProductSchema.__schema__(:fields, :nonexistent)

      assert fields == []
    end

    test "each item is a Field struct" do
      fields = ProductSchema.__schema__(:fields, :product)

      Enum.each(fields, fn field ->
        assert %Field{} = field
        assert is_atom(field.name)
        assert is_atom(field.type)
      end)
    end

    test "fields have correct types" do
      fields = ProductSchema.__schema__(:fields, :product)

      id_field = Enum.find(fields, &(&1.name == :id))
      assert id_field.type == :string

      price_field = Enum.find(fields, &(&1.name == :price))
      assert price_field.type == :integer

      metadata_field = Enum.find(fields, &(&1.name == :metadata))
      assert metadata_field.type == :map
    end
  end

  # RMX002_6A_T4: Test fields in correct order
  describe "field order preservation" do
    defmodule OrderedSchema do
      use PState.Schema

      entity :card do
        field(:id, :string)
        field(:front, :string)
        field(:back, :string)
        field(:created_at, :integer)
        field(:updated_at, :integer)
      end
    end

    test "fields are returned in definition order" do
      fields = OrderedSchema.__schema__(:fields, :card)

      names = Enum.map(fields, & &1.name)

      assert names == [:id, :front, :back, :created_at, :updated_at]
    end

    test "__schema__(:entity, name) also preserves order" do
      fields = OrderedSchema.__schema__(:entity, :card)

      names = Enum.map(fields, & &1.name)

      assert names == [:id, :front, :back, :created_at, :updated_at]
    end
  end

  # RMX002_6A_T5: Test compilation with complete schema (all field types)
  describe "complete schema compilation" do
    defmodule CompleteSchema do
      use PState.Schema

      entity :base_card do
        field(:id, :string)
        field(:front, :string)
        field(:back, :string)
        field(:created_at, :integer)

        belongs_to(:deck, ref: :base_deck)

        field :metadata, :map do
          migrate(fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
            nil -> %{}
          end)
        end

        field(:tags, :list)
      end

      entity :host_card do
        field(:id, :string)
        field(:country, :string)

        belongs_to :base_card, ref: :base_card do
          migrate(fn
            id when is_binary(id) -> PState.Ref.new(:base_card, id)
            %PState.Ref{} = ref -> ref
          end)
        end

        has_many :translations, ref: :translation do
          migrate(fn
            ids when is_list(ids) ->
              Map.new(ids, &{&1, PState.Ref.new(:translation, &1)})

            refs when is_map(refs) ->
              refs

            nil ->
              %{}
          end)
        end
      end

      entity :base_deck do
        field(:id, :string)
        field(:name, :string)

        has_many(:cards, ref: :base_card)
      end
    end

    test "compiles schema with all entity types" do
      entities = CompleteSchema.__schema__(:entities)

      assert Map.has_key?(entities, :base_card)
      assert Map.has_key?(entities, :host_card)
      assert Map.has_key?(entities, :base_deck)
    end

    test "handles simple fields correctly" do
      fields = CompleteSchema.__schema__(:fields, :base_card)

      id_field = Enum.find(fields, &(&1.name == :id))
      assert id_field.type == :string
      assert id_field.migrate_fn == nil

      created_at_field = Enum.find(fields, &(&1.name == :created_at))
      assert created_at_field.type == :integer
    end

    test "handles belongs_to fields correctly" do
      fields = CompleteSchema.__schema__(:fields, :base_card)

      deck_field = Enum.find(fields, &(&1.name == :deck))
      assert deck_field.type == :ref
      assert deck_field.ref_type == :base_deck
      assert deck_field.migrate_fn == nil
    end

    test "handles belongs_to with migration correctly" do
      fields = CompleteSchema.__schema__(:fields, :host_card)

      base_card_field = Enum.find(fields, &(&1.name == :base_card))
      assert base_card_field.type == :ref
      assert base_card_field.ref_type == :base_card
      assert is_function(base_card_field.migrate_fn, 1)

      # Test migration function works
      result = base_card_field.migrate_fn.("some_id")
      assert %PState.Ref{} = result
    end

    test "handles has_many fields correctly" do
      fields = CompleteSchema.__schema__(:fields, :base_deck)

      cards_field = Enum.find(fields, &(&1.name == :cards))
      assert cards_field.type == :collection
      assert cards_field.ref_type == :base_card
      assert cards_field.migrate_fn == nil
    end

    test "handles has_many with migration correctly" do
      fields = CompleteSchema.__schema__(:fields, :host_card)

      translations_field = Enum.find(fields, &(&1.name == :translations))
      assert translations_field.type == :collection
      assert translations_field.ref_type == :translation
      assert is_function(translations_field.migrate_fn, 1)

      # Test migration function works
      result = translations_field.migrate_fn.(["t1", "t2"])
      assert is_map(result)
      assert Map.has_key?(result, "t1")
      assert %PState.Ref{} = result["t1"]
    end

    test "handles field with migration correctly" do
      fields = CompleteSchema.__schema__(:fields, :base_card)

      metadata_field = Enum.find(fields, &(&1.name == :metadata))
      assert metadata_field.type == :map
      assert is_function(metadata_field.migrate_fn, 1)

      # Test migration function works
      assert metadata_field.migrate_fn.("notes") == %{notes: "notes"}
      assert metadata_field.migrate_fn.(%{key: "value"}) == %{key: "value"}
      assert metadata_field.migrate_fn.(nil) == %{}
    end

    test "all fields in base_card are in correct order" do
      fields = CompleteSchema.__schema__(:fields, :base_card)
      names = Enum.map(fields, & &1.name)

      assert names == [:id, :front, :back, :created_at, :deck, :metadata, :tags]
    end

    test "all fields in host_card are in correct order" do
      fields = CompleteSchema.__schema__(:fields, :host_card)
      names = Enum.map(fields, & &1.name)

      assert names == [:id, :country, :base_card, :translations]
    end

    test "migration function references are stored correctly" do
      fields = CompleteSchema.__schema__(:fields, :base_card)

      metadata_field = Enum.find(fields, &(&1.name == :metadata))
      assert metadata_field.migrate_fn_ref != nil
      {module, fn_name} = metadata_field.migrate_fn_ref
      assert module == CompleteSchema
      assert is_atom(fn_name)
    end
  end

  # Additional test: Empty schema
  describe "empty schema" do
    defmodule EmptySchema do
      use PState.Schema
    end

    test "returns empty map for entities" do
      entities = EmptySchema.__schema__(:entities)

      assert entities == %{}
    end

    test "returns nil for non-existent entity" do
      assert EmptySchema.__schema__(:entity, :anything) == nil
    end

    test "returns empty list for fields of non-existent entity" do
      assert EmptySchema.__schema__(:fields, :anything) == []
    end
  end

  # Additional test: Single entity, single field
  describe "minimal schema" do
    defmodule MinimalSchema do
      use PState.Schema

      entity :simple do
        field(:id, :string)
      end
    end

    test "compiles correctly" do
      entities = MinimalSchema.__schema__(:entities)

      assert Map.keys(entities) == [:simple]
      assert length(entities[:simple]) == 1
    end

    test "field has correct properties" do
      fields = MinimalSchema.__schema__(:fields, :simple)

      assert length(fields) == 1
      field = hd(fields)
      assert field.name == :id
      assert field.type == :string
      assert field.migrate_fn == nil
    end
  end
end
