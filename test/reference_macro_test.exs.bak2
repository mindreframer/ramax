defmodule PState.ReferenceMacroTest do
  use ExUnit.Case, async: true

  alias PState.Schema.Field

  describe "RMX002_5A_T1: belongs_to/2 simple" do
    test "belongs_to/2 creates a Field struct with :ref type" do
      defmodule SimpleBelongsToSchema do
        use PState.Schema

        entity :base_card do
          belongs_to(:deck, ref: :base_deck)
        end
      end

      fields = SimpleBelongsToSchema.__schema__(:fields, :base_card)
      assert length(fields) == 1

      field = List.first(fields)
      assert %Field{} = field
      assert field.name == :deck
      assert field.type == :ref
      assert field.ref_type == :base_deck
      assert field.migrate_fn == nil
      assert field.opts == [ref: :base_deck]
    end

    test "belongs_to/2 preserves opts including :ref" do
      defmodule BelongsToWithOptsSchema do
        use PState.Schema

        entity :host_card do
          belongs_to(:base_card, ref: :base_card, optional: false)
        end
      end

      fields = BelongsToWithOptsSchema.__schema__(:fields, :host_card)
      field = List.first(fields)

      assert field.name == :base_card
      assert field.type == :ref
      assert field.ref_type == :base_card
      assert field.opts == [ref: :base_card, optional: false]
    end

    test "belongs_to/2 can define multiple reference fields" do
      defmodule MultipleBelongsToSchema do
        use PState.Schema

        entity :translation do
          belongs_to(:base_card, ref: :base_card)
          belongs_to(:host_card, ref: :host_card)
          belongs_to(:language, ref: :language)
        end
      end

      fields = MultipleBelongsToSchema.__schema__(:fields, :translation)
      assert length(fields) == 3

      field_names = Enum.map(fields, & &1.name)
      assert :base_card in field_names
      assert :host_card in field_names
      assert :language in field_names

      # All should be :ref type
      assert Enum.all?(fields, fn f -> f.type == :ref end)
    end
  end

  describe "RMX002_5A_T2: belongs_to sets ref_type" do
    test "belongs_to/2 extracts :ref from opts and sets ref_type" do
      defmodule RefTypeExtractionSchema do
        use PState.Schema

        entity :card do
          belongs_to(:deck, ref: :deck_entity)
        end
      end

      fields = RefTypeExtractionSchema.__schema__(:fields, :card)
      field = List.first(fields)

      # ref_type should be set from the :ref opt
      assert field.ref_type == :deck_entity
    end

    test "belongs_to/2 sets correct ref_type for different entities" do
      defmodule MultiRefTypeSchema do
        use PState.Schema

        entity :review do
          belongs_to(:user, ref: :user_entity)
          belongs_to(:product, ref: :product_entity)
          belongs_to(:store, ref: :store_entity)
        end
      end

      fields = MultiRefTypeSchema.__schema__(:fields, :review)

      user_field = Enum.find(fields, fn f -> f.name == :user end)
      assert user_field.ref_type == :user_entity

      product_field = Enum.find(fields, fn f -> f.name == :product end)
      assert product_field.ref_type == :product_entity

      store_field = Enum.find(fields, fn f -> f.name == :store end)
      assert store_field.ref_type == :store_entity
    end

    test "belongs_to/2 ref_type matches the entity being referenced" do
      defmodule RefTypeMatchSchema do
        use PState.Schema

        entity :comment do
          belongs_to(:post, ref: :blog_post)
        end
      end

      fields = RefTypeMatchSchema.__schema__(:fields, :comment)
      field = List.first(fields)

      # The ref_type should match what was specified in opts
      assert field.ref_type == :blog_post
      assert field.type == :ref
    end
  end

  describe "RMX002_5A_T3: belongs_to/3 with migration" do
    test "belongs_to/3 creates Field with migration function" do
      defmodule BelongsToWithMigrationSchema do
        use PState.Schema

        entity :host_card do
          belongs_to :base_card, ref: :base_card do
            migrate(fn
              id when is_binary(id) -> {:ref, :base_card, id}
              %{type: :ref, entity: e, id: i} -> {:ref, e, i}
            end)
          end
        end
      end

      fields = BelongsToWithMigrationSchema.__schema__(:fields, :host_card)
      field = List.first(fields)

      assert field.name == :base_card
      assert field.type == :ref
      assert field.ref_type == :base_card
      assert field.migrate_fn != nil
      assert is_function(field.migrate_fn, 1)
    end

    test "belongs_to/3 migration function is callable and works" do
      defmodule CallableBelongsToMigrationSchema do
        use PState.Schema

        entity :card do
          belongs_to :deck, ref: :base_deck do
            migrate(fn
              id when is_binary(id) -> {:migrated, id}
              other -> other
            end)
          end
        end
      end

      fields = CallableBelongsToMigrationSchema.__schema__(:fields, :card)
      field = List.first(fields)

      # Test migration function
      assert field.migrate_fn.("test_id") == {:migrated, "test_id"}
      assert field.migrate_fn.(123) == 123
    end

    test "belongs_to/3 with migration handles multiple clauses" do
      defmodule MultiClauseBelongsToSchema do
        use PState.Schema

        entity :review do
          belongs_to :product, ref: :product do
            migrate(fn
              # Old format: just ID
              id when is_binary(id) -> %{entity: :product, id: id}
              # Current format: map
              %{entity: _e, id: _i} = ref -> ref
              # Nil case
              nil -> nil
            end)
          end
        end
      end

      fields = MultiClauseBelongsToSchema.__schema__(:fields, :review)
      field = List.first(fields)

      assert field.migrate_fn.("abc123") == %{entity: :product, id: "abc123"}
      assert field.migrate_fn.(%{entity: :product, id: "xyz"}) == %{entity: :product, id: "xyz"}
      assert field.migrate_fn.(nil) == nil
    end

    test "belongs_to/3 preserves both migration and opts" do
      defmodule BelongsToMigrationOptsSchema do
        use PState.Schema

        entity :task do
          belongs_to :project, ref: :project, required: true do
            migrate(fn
              id when is_binary(id) -> {:ref, id}
              ref -> ref
            end)
          end
        end
      end

      fields = BelongsToMigrationOptsSchema.__schema__(:fields, :task)
      field = List.first(fields)

      assert field.name == :project
      assert field.ref_type == :project
      assert field.migrate_fn != nil
      assert field.opts == [ref: :project, required: true]
    end
  end

  describe "RMX002_5A_T4: has_many/2 simple" do
    test "has_many/2 creates a Field struct with :collection type" do
      defmodule SimpleHasManySchema do
        use PState.Schema

        entity :base_deck do
          has_many(:cards, ref: :base_card)
        end
      end

      fields = SimpleHasManySchema.__schema__(:fields, :base_deck)
      assert length(fields) == 1

      field = List.first(fields)
      assert %Field{} = field
      assert field.name == :cards
      assert field.type == :collection
      assert field.ref_type == :base_card
      assert field.migrate_fn == nil
      assert field.opts == [ref: :base_card]
    end

    test "has_many/2 preserves opts including :ref" do
      defmodule HasManyWithOptsSchema do
        use PState.Schema

        entity :user do
          has_many(:posts, ref: :blog_post, cascade: true)
        end
      end

      fields = HasManyWithOptsSchema.__schema__(:fields, :user)
      field = List.first(fields)

      assert field.name == :posts
      assert field.type == :collection
      assert field.ref_type == :blog_post
      assert field.opts == [ref: :blog_post, cascade: true]
    end

    test "has_many/2 can define multiple collection fields" do
      defmodule MultipleHasManySchema do
        use PState.Schema

        entity :organization do
          has_many(:users, ref: :user)
          has_many(:projects, ref: :project)
          has_many(:teams, ref: :team)
        end
      end

      fields = MultipleHasManySchema.__schema__(:fields, :organization)
      assert length(fields) == 3

      field_names = Enum.map(fields, & &1.name)
      assert :users in field_names
      assert :projects in field_names
      assert :teams in field_names

      # All should be :collection type
      assert Enum.all?(fields, fn f -> f.type == :collection end)
    end
  end

  describe "RMX002_5A_T5: has_many sets type :collection" do
    test "has_many/2 sets type to :collection" do
      defmodule CollectionTypeSchema do
        use PState.Schema

        entity :deck do
          has_many(:cards, ref: :card)
        end
      end

      fields = CollectionTypeSchema.__schema__(:fields, :deck)
      field = List.first(fields)

      # Type must be :collection, not :ref
      assert field.type == :collection
      refute field.type == :ref
    end

    test "has_many/2 type :collection differs from belongs_to :ref" do
      defmodule TypeDifferenceSchema do
        use PState.Schema

        entity :mixed do
          belongs_to(:parent, ref: :parent_entity)
          has_many(:children, ref: :child_entity)
        end
      end

      fields = TypeDifferenceSchema.__schema__(:fields, :mixed)

      parent_field = Enum.find(fields, fn f -> f.name == :parent end)
      children_field = Enum.find(fields, fn f -> f.name == :children end)

      # belongs_to should be :ref
      assert parent_field.type == :ref

      # has_many should be :collection
      assert children_field.type == :collection

      # They should be different
      refute parent_field.type == children_field.type
    end

    test "has_many/2 sets ref_type correctly for collection" do
      defmodule CollectionRefTypeSchema do
        use PState.Schema

        entity :author do
          has_many(:books, ref: :book_entity)
        end
      end

      fields = CollectionRefTypeSchema.__schema__(:fields, :author)
      field = List.first(fields)

      assert field.type == :collection
      assert field.ref_type == :book_entity
    end
  end

  describe "RMX002_5A_T6: has_many/3 with migration" do
    test "has_many/3 creates Field with migration function" do
      defmodule HasManyWithMigrationSchema do
        use PState.Schema

        entity :host_card do
          has_many :translations, ref: :translation do
            migrate(fn
              ids when is_list(ids) -> Map.new(ids, &{&1, {:ref, :translation, &1}})
              refs when is_map(refs) -> refs
            end)
          end
        end
      end

      fields = HasManyWithMigrationSchema.__schema__(:fields, :host_card)
      field = List.first(fields)

      assert field.name == :translations
      assert field.type == :collection
      assert field.ref_type == :translation
      assert field.migrate_fn != nil
      assert is_function(field.migrate_fn, 1)
    end

    test "has_many/3 migration function is callable and works" do
      defmodule CallableHasManyMigrationSchema do
        use PState.Schema

        entity :deck do
          has_many :cards, ref: :card do
            migrate(fn
              ids when is_list(ids) -> {:migrated_list, ids}
              map when is_map(map) -> {:migrated_map, map}
            end)
          end
        end
      end

      fields = CallableHasManyMigrationSchema.__schema__(:fields, :deck)
      field = List.first(fields)

      # Test migration function with list
      assert field.migrate_fn.(["a", "b", "c"]) == {:migrated_list, ["a", "b", "c"]}

      # Test migration function with map
      assert field.migrate_fn.(%{x: 1}) == {:migrated_map, %{x: 1}}
    end

    test "has_many/3 with migration handles list to map conversion" do
      defmodule ListToMapHasManySchema do
        use PState.Schema

        entity :collection do
          has_many :items, ref: :item do
            migrate(fn
              # Old: list of IDs
              ids when is_list(ids) ->
                Map.new(ids, fn id -> {id, %{id: id, entity: :item}} end)

              # Current: map
              refs when is_map(refs) ->
                refs

              # Nil case
              nil ->
                %{}
            end)
          end
        end
      end

      fields = ListToMapHasManySchema.__schema__(:fields, :collection)
      field = List.first(fields)

      # Test list conversion
      result = field.migrate_fn.(["id1", "id2"])
      assert is_map(result)
      assert result["id1"] == %{id: "id1", entity: :item}
      assert result["id2"] == %{id: "id2", entity: :item}

      # Test map passthrough
      input_map = %{"x" => %{id: "x", entity: :item}}
      assert field.migrate_fn.(input_map) == input_map

      # Test nil case
      assert field.migrate_fn.(nil) == %{}
    end

    test "has_many/3 preserves both migration and opts" do
      defmodule HasManyMigrationOptsSchema do
        use PState.Schema

        entity :blog do
          has_many :posts, ref: :post, ordered: true do
            migrate(fn
              ids when is_list(ids) -> %{ids: ids}
              refs -> refs
            end)
          end
        end
      end

      fields = HasManyMigrationOptsSchema.__schema__(:fields, :blog)
      field = List.first(fields)

      assert field.name == :posts
      assert field.type == :collection
      assert field.ref_type == :post
      assert field.migrate_fn != nil
      assert field.opts == [ref: :post, ordered: true]
    end

    test "has_many/3 migration works with complex transformations" do
      defmodule ComplexHasManyMigrationSchema do
        use PState.Schema

        entity :library do
          has_many :books, ref: :book do
            migrate(fn
              # Legacy: array of book IDs
              ids when is_list(ids) and is_binary(hd(ids)) ->
                Map.new(ids, &{&1, %{type: :ref, entity: :book, id: &1}})

              # Legacy: array of {id, data} tuples
              tuples when is_list(tuples) and is_tuple(hd(tuples)) ->
                Map.new(tuples)

              # Current: map of id -> ref
              refs when is_map(refs) ->
                refs

              # Empty/nil
              _ ->
                %{}
            end)
          end
        end
      end

      fields = ComplexHasManyMigrationSchema.__schema__(:fields, :library)
      field = List.first(fields)

      # Test string list
      result1 = field.migrate_fn.(["book1", "book2"])
      assert result1["book1"] == %{type: :ref, entity: :book, id: "book1"}

      # Test tuple list
      result2 = field.migrate_fn.([{"id1", :data1}, {"id2", :data2}])
      assert result2["id1"] == :data1

      # Test map
      input_map = %{"x" => :ref}
      assert field.migrate_fn.(input_map) == input_map

      # Test nil
      assert field.migrate_fn.(nil) == %{}
    end
  end
end
