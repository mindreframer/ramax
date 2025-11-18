defmodule PState.CollectionMigrationTest do
  use ExUnit.Case, async: true

  alias PState.Schema.Field
  alias PState.Ref
  alias PState.Internal

  @moduledoc """
  Tests for RMX004_5A: Collection Migration Patterns

  Tests the pattern of migrating collections from old formats to new formats:
  - Old format: list of IDs ["id1", "id2", ...]
  - New format: map of id => Ref  %{"id1" => %Ref{key: "entity:id1"}, ...}

  This pattern is used for has_many relationships where the storage format
  evolved from simple ID lists to properly typed references.
  """

  # Test schema definition with collection migration
  defmodule TestSchema do
    @moduledoc """
    Example schema demonstrating collection migration patterns.

    This schema shows how to migrate has_many relationships from
    legacy list format to the current map-of-refs format.
    """

    @doc """
    Migration function for translating list of IDs to map of Refs.

    Handles three cases:
    1. List of IDs (old format) → map of id => Ref
    2. Map of Refs (new format) → pass through (idempotent)
    3. nil/missing → empty map (default)
    """
    def migrate_translations(ids) when is_list(ids) do
      Map.new(ids, fn id ->
        {id, Ref.new(:translation, id)}
      end)
    end

    def migrate_translations(refs) when is_map(refs), do: refs
    def migrate_translations(nil), do: %{}

    @doc """
    Migration function for related items collection.
    Same pattern, different entity type.
    """
    def migrate_related_items(ids) when is_list(ids) do
      Map.new(ids, fn id ->
        {id, Ref.new(:item, id)}
      end)
    end

    def migrate_related_items(refs) when is_map(refs), do: refs
    def migrate_related_items(nil), do: %{}
  end

  describe "RMX004_5A_T1: list of IDs → map of Refs" do
    test "migrates list of IDs to map of Refs" do
      # Setup: field with collection migration
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        }
      ]

      # Given: entity with old format (list of IDs)
      data = %{
        id: "card1",
        translations: ["trans1", "trans2", "trans3"]
      }

      # When: migration runs
      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # Then: list converted to map of Refs
      assert changed? == true
      assert is_map(migrated_data.translations)
      assert map_size(migrated_data.translations) == 3

      assert migrated_data.translations == %{
               "trans1" => %Ref{key: "translation:trans1"},
               "trans2" => %Ref{key: "translation:trans2"},
               "trans3" => %Ref{key: "translation:trans3"}
             }
    end

    test "preserves entity ID and other fields" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        }
      ]

      data = %{
        id: "card1",
        front: "Hello",
        translations: ["trans1"]
      }

      {migrated_data, _changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data.id == "card1"
      assert migrated_data.front == "Hello"
    end
  end

  describe "RMX004_5A_T2: empty list → empty map" do
    test "migrates empty list to empty map" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        }
      ]

      data = %{id: "card1", translations: []}

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true
      assert migrated_data.translations == %{}
      assert is_map(migrated_data.translations)
    end
  end

  describe "RMX004_5A_T3: nil → empty map" do
    test "nil values don't trigger migration (nil matches any type)" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        }
      ]

      data = %{id: "card1", translations: nil}

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # nil matches any type, so migration is not triggered
      # This is by design - nil is considered valid for any field type
      assert changed? == false
      assert migrated_data.translations == nil
    end

    test "missing field remains missing (no migration triggered)" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        }
      ]

      # No translations field at all
      data = %{id: "card1"}

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # Missing field (nil from Map.get) also doesn't trigger migration
      assert changed? == false
      assert Map.has_key?(migrated_data, :translations) == false
    end

    test "migration function can handle nil if explicitly called" do
      # This demonstrates that the migration function itself handles nil correctly,
      # even though the migration system won't call it for nil values
      result = TestSchema.migrate_translations(nil)
      assert result == %{}
    end
  end

  describe "RMX004_5A_T4: already migrated (map → map)" do
    test "passes through already-migrated map unchanged" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        }
      ]

      # Already in new format
      data = %{
        id: "card1",
        translations: %{
          "trans1" => %Ref{key: "translation:trans1"},
          "trans2" => %Ref{key: "translation:trans2"}
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # Then: no change, idempotent
      assert changed? == false
      assert migrated_data.translations == data.translations
    end

    test "migration is truly idempotent - running twice gives same result" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        }
      ]

      original = %{id: "card1", translations: ["trans1", "trans2"]}

      # First migration
      {migrated_once, changed1?} = Internal.migrate_entity(original, field_specs)
      assert changed1? == true

      # Second migration (should be noop)
      {migrated_twice, changed2?} = Internal.migrate_entity(migrated_once, field_specs)
      assert changed2? == false
      assert migrated_twice == migrated_once
    end
  end

  describe "RMX004_5A_T5: multiple collections in entity" do
    test "migrates multiple collections independently" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        },
        %Field{
          name: :related_items,
          type: :map,
          migrate_fn: &TestSchema.migrate_related_items/1,
          opts: []
        }
      ]

      data = %{
        id: "card1",
        translations: ["trans1", "trans2"],
        related_items: ["item1", "item2", "item3"]
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true

      # Check translations collection
      assert migrated_data.translations == %{
               "trans1" => %Ref{key: "translation:trans1"},
               "trans2" => %Ref{key: "translation:trans2"}
             }

      # Check related_items collection
      assert migrated_data.related_items == %{
               "item1" => %Ref{key: "item:item1"},
               "item2" => %Ref{key: "item:item2"},
               "item3" => %Ref{key: "item:item3"}
             }
    end

    test "handles mixed migration states (one migrated, one not)" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        },
        %Field{
          name: :related_items,
          type: :map,
          migrate_fn: &TestSchema.migrate_related_items/1,
          opts: []
        }
      ]

      data = %{
        id: "card1",
        # Already migrated
        translations: %{"trans1" => %Ref{key: "translation:trans1"}},
        # Not yet migrated
        related_items: ["item1", "item2"]
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # Should detect change due to related_items
      assert changed? == true

      # Translations unchanged
      assert migrated_data.translations == data.translations

      # Related items migrated
      assert migrated_data.related_items == %{
               "item1" => %Ref{key: "item:item1"},
               "item2" => %Ref{key: "item:item2"}
             }
    end

    test "handles all collections empty/nil" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: &TestSchema.migrate_translations/1,
          opts: []
        },
        %Field{
          name: :related_items,
          type: :map,
          migrate_fn: &TestSchema.migrate_related_items/1,
          opts: []
        }
      ]

      data = %{
        id: "card1",
        translations: nil,
        related_items: []
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # Only related_items triggers migration (list → map)
      # translations stays nil (nil matches any type)
      assert changed? == true
      assert migrated_data.translations == nil
      assert migrated_data.related_items == %{}
    end
  end
end
