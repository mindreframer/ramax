defmodule PState.FieldRenameTest do
  use ExUnit.Case, async: true

  alias PState.Schema.Field
  alias PState.Internal

  @moduledoc """
  Tests for RMX004_7A: Field Rename Patterns

  Tests the pattern of migrating data when a field is renamed:
  - Old format: data stored under old field name (e.g., "notes")
  - New format: data stored under new field name (e.g., "metadata")

  This pattern is used when refactoring schemas to use better field names
  while maintaining backward compatibility with existing data.

  Note: The old field remains in the data (no automatic cleanup).
  Cleanup can be done manually or via an after_migrate hook if needed.
  """

  # Test schema definition with field rename migration
  defmodule TestSchema do
    @moduledoc """
    Example schema demonstrating field rename migration patterns.

    This schema shows how to migrate data from old field names to new
    field names while maintaining backward compatibility.
    """

    @doc """
    Migration function for metadata field - reads from old "notes" field.

    In a real system, the raw data would have the old field name.
    The migration reads from the old location and returns the value
    to be stored under the new field name.

    Handles cases:
    1. nil (new field) but data available elsewhere → handled by entity-level logic
    2. String value already in new field → pass through (idempotent)
    3. nil and no old data → default value
    """
    def migrate_metadata(value, raw_data \\ %{}) do
      case value do
        # If new field has value, use it (already migrated)
        val when is_map(val) and not is_struct(val) ->
          val

        # If new field is nil, try to read from old field
        nil ->
          case Map.get(raw_data, :notes) || Map.get(raw_data, "notes") do
            notes when is_binary(notes) ->
              # Migrate old string notes to new metadata structure
              %{notes: notes, created_at: nil}

            _ ->
              # Default value
              %{notes: "", created_at: nil}
          end

        # If new field exists but is unexpected type, default
        _ ->
          %{notes: "", created_at: nil}
      end
    end

    @doc """
    Validation function for metadata field.
    Returns true if value is in correct format, false otherwise.
    """
    def validate_metadata(nil), do: false
    def validate_metadata(%{notes: _, created_at: _}), do: true
    def validate_metadata(_), do: false

    @doc """
    Migration function for settings field - reads from old "preferences" field.

    Old format: stored in "preferences" as simple string
    New format: stored in "settings" as structured map
    """
    def migrate_settings(value, raw_data \\ %{}) do
      case value do
        # Already in new format
        %{theme: _, lang: _} = settings ->
          settings

        # New field is nil, check old field
        nil ->
          case Map.get(raw_data, :preferences) || Map.get(raw_data, "preferences") do
            prefs when is_binary(prefs) ->
              # Parse old preferences string (simplified example)
              %{theme: prefs, lang: "en"}

            _ ->
              %{theme: "default", lang: "en"}
          end

        _ ->
          %{theme: "default", lang: "en"}
      end
    end

    @doc """
    Validation function for settings field.
    """
    def validate_settings(%{theme: _, lang: _}), do: true
    def validate_settings(_), do: false

    @doc """
    Migration function for user_email - reads from old "email" field.

    This demonstrates a simple rename where the value type doesn't change,
    just the field name.
    """
    def migrate_user_email(value, raw_data \\ %{}) do
      case value do
        # Already has value in new field
        email when is_binary(email) ->
          email

        # New field is nil, read from old field
        nil ->
          Map.get(raw_data, :email) || Map.get(raw_data, "email") || ""

        _ ->
          ""
      end
    end

    @doc """
    Validation function for user_email.
    """
    def validate_user_email(email) when is_binary(email), do: true
    def validate_user_email(_), do: false
  end

  describe "RMX004_7A_T1: read from old field name" do
    test "migrates string from old 'notes' field to new 'metadata' field" do
      # In this test we simulate what happens when:
      # - Old data has "notes" field
      # - New schema expects "metadata" field
      # - Migration needs to read from old field

      # NOTE: Since the migration system currently doesn't pass raw_data
      # to migrate functions, we'll test the migration function directly
      # to demonstrate the pattern.

      raw_data = %{
        id: "user1",
        notes: "Important information"
      }

      # Call migration function directly (pattern demonstration)
      result = TestSchema.migrate_metadata(nil, raw_data)

      assert result == %{
               notes: "Important information",
               created_at: nil
             }
    end

    test "migrates preferences to settings" do
      raw_data = %{
        id: "user1",
        preferences: "dark_mode"
      }

      result = TestSchema.migrate_settings(nil, raw_data)

      assert result == %{
               theme: "dark_mode",
               lang: "en"
             }
    end

    test "simple field rename - email to user_email" do
      raw_data = %{
        id: "user1",
        email: "user@example.com"
      }

      result = TestSchema.migrate_user_email(nil, raw_data)

      assert result == "user@example.com"
    end

    test "reads from old field when new field is nil" do
      raw_data = %{
        id: "doc1",
        notes: "Legacy notes here",
        metadata: nil
      }

      result = TestSchema.migrate_metadata(nil, raw_data)

      assert result.notes == "Legacy notes here"
    end
  end

  describe "RMX004_7A_T2: write to new field name" do
    test "migration returns value for new field name" do
      raw_data = %{id: "user1", notes: "Test notes"}

      result = TestSchema.migrate_metadata(nil, raw_data)

      # Result will be stored under "metadata" field
      assert is_map(result)
      assert result.notes == "Test notes"
    end

    test "newly written data uses new field name" do
      # When we explicitly set the new field, it should be used
      new_metadata = %{
        notes: "New format notes",
        created_at: ~U[2024-01-01 00:00:00Z]
      }

      result = TestSchema.migrate_metadata(new_metadata, %{})

      assert result == new_metadata
    end

    test "new data doesn't read from old field if new field exists" do
      raw_data = %{
        id: "user1",
        notes: "Old notes",
        metadata: %{notes: "New notes", created_at: nil}
      }

      result = TestSchema.migrate_metadata(raw_data.metadata, raw_data)

      # Should use new field value, not old
      assert result.notes == "New notes"
    end
  end

  describe "RMX004_7A_T3: old field still present (no cleanup)" do
    test "migration doesn't remove old field" do
      # This test demonstrates that the old field remains in the data
      # The migration only reads from it, doesn't delete it

      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          # Note: Current system doesn't pass raw_data to migrate_fn
          # This is a limitation we're documenting
          migrate_fn: fn val -> TestSchema.migrate_metadata(val, %{}) end,
          validate_fn: &TestSchema.validate_metadata/1,
          opts: []
        }
      ]

      data = %{
        id: "user1",
        notes: "Original notes",
        metadata: nil
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # Old field should still be present
      assert Map.has_key?(migrated_data, :notes)
      assert migrated_data.notes == "Original notes"

      # New field should be created with default since we can't access raw_data
      # In real implementation, this would need raw_data access
      assert changed? == true
      assert Map.has_key?(migrated_data, :metadata)
    end

    test "both old and new fields coexist after migration" do
      field_specs = [
        %Field{
          name: :settings,
          type: :map,
          migrate_fn: fn val -> TestSchema.migrate_settings(val, %{}) end,
          validate_fn: &TestSchema.validate_settings/1,
          opts: []
        }
      ]

      data = %{
        id: "user1",
        preferences: "light_theme",
        settings: nil
      }

      {migrated_data, _changed?} = Internal.migrate_entity(data, field_specs)

      # Old field still present
      assert migrated_data.preferences == "light_theme"
      # New field created
      assert Map.has_key?(migrated_data, :settings)
    end

    test "old field can be manually cleaned up later if needed" do
      # This documents the cleanup strategy:
      # After migration, old fields can be removed manually

      data = %{
        id: "user1",
        notes: "Old data",
        metadata: %{notes: "New data", created_at: nil}
      }

      # Manual cleanup: remove old field
      cleaned_data = Map.delete(data, :notes)

      assert not Map.has_key?(cleaned_data, :notes)
      assert Map.has_key?(cleaned_data, :metadata)
    end
  end

  describe "RMX004_7A_T4: already migrated (new field exists)" do
    test "passes through when new field already has value" do
      existing_metadata = %{
        notes: "Already migrated",
        created_at: ~U[2024-01-01 00:00:00Z]
      }

      result = TestSchema.migrate_metadata(existing_metadata, %{notes: "Old"})

      # Should use existing value, ignore old field
      assert result == existing_metadata
      assert result.notes == "Already migrated"
    end

    test "migration is idempotent" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn val -> TestSchema.migrate_metadata(val, %{}) end,
          validate_fn: &TestSchema.validate_metadata/1,
          opts: []
        }
      ]

      # Data already migrated
      data = %{
        id: "user1",
        metadata: %{notes: "Current data", created_at: nil}
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # No change needed
      assert changed? == false
      assert migrated_data.metadata == data.metadata
    end

    test "settings already in new format not re-migrated" do
      existing_settings = %{theme: "dark", lang: "es"}

      result = TestSchema.migrate_settings(existing_settings, %{preferences: "old"})

      assert result == existing_settings
      assert result.theme == "dark"
      assert result.lang == "es"
    end

    test "multiple migrations - some done, some pending" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn val -> TestSchema.migrate_metadata(val, %{}) end,
          validate_fn: &TestSchema.validate_metadata/1,
          opts: []
        },
        %Field{
          name: :settings,
          type: :map,
          migrate_fn: fn val -> TestSchema.migrate_settings(val, %{}) end,
          validate_fn: &TestSchema.validate_settings/1,
          opts: []
        }
      ]

      data = %{
        id: "user1",
        # Already migrated
        metadata: %{notes: "Done", created_at: nil},
        # Not yet migrated (nil)
        settings: nil
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # Should detect change due to settings
      assert changed? == true

      # Metadata unchanged
      assert migrated_data.metadata == data.metadata

      # Settings migrated with default
      assert migrated_data.settings == %{theme: "default", lang: "en"}
    end
  end
end
