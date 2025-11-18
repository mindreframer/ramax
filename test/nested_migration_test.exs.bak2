defmodule PState.NestedMigrationTest do
  use ExUnit.Case, async: true

  alias PState.Schema.Field
  alias PState.Internal

  @moduledoc """
  Tests for RMX004_6A: Nested Field Migration Patterns

  Tests the pattern of migrating nested structures to flat structures:
  - Old format: nested maps %{url: %{primary: "...", format: "..."}}
  - New format: flat maps %{url: "...", format: "..."}

  This pattern is used when simplifying data structures by flattening
  nested fields into a single level.
  """

  # Test schema definition with nested field migration
  defmodule TestSchema do
    @moduledoc """
    Example schema demonstrating nested field migration patterns.

    This schema shows how to migrate nested structures to flat structures,
    handling various edge cases like missing fields and partial nesting.
    """

    @doc """
    Migration function for audio field - flattens nested URL structure.

    Handles cases:
    1. Nested structure (old format) → flat map
    2. Flat map (new format) → pass through (idempotent)
    3. nil/missing → default structure
    """
    def migrate_audio(%{url: %{primary: url, format: fmt}}) do
      %{url: url, format: fmt}
    end

    def migrate_audio(%{url: _, format: _} = audio), do: audio
    def migrate_audio(nil), do: %{url: nil, format: "mp3"}

    @doc """
    Validation function for audio field - checks if audio is in correct flat format.
    Returns true if valid (flat or nil), false if needs migration (nested).
    """
    def validate_audio(nil), do: true
    def validate_audio(%{url: url, format: _fmt}) when not is_map(url), do: true
    def validate_audio(_), do: false

    @doc """
    Migration function for config field - handles deep nesting (3 levels).

    Old format: %{settings: %{display: %{theme: "dark", size: 12}}}
    New format: %{theme: "dark", size: 12}
    """
    def migrate_config(%{settings: %{display: display_map}}) when is_map(display_map) do
      display_map
    end

    def migrate_config(%{theme: _, size: _} = config), do: config
    def migrate_config(nil), do: %{theme: "light", size: 14}

    @doc """
    Validation function for config - checks if config is in correct flat format.
    """
    def validate_config(%{theme: _, size: _}), do: true
    def validate_config(_), do: false

    @doc """
    Migration function for metadata - handles partial nesting.

    Old format: %{info: %{title: "..."}, version: 1}
    New format: %{title: "...", version: 1}
    """
    def migrate_metadata(%{info: %{title: title}, version: version}) do
      %{title: title, version: version}
    end

    def migrate_metadata(%{info: %{title: title}}) do
      %{title: title, version: 1}
    end

    def migrate_metadata(%{title: _, version: _} = metadata), do: metadata
    def migrate_metadata(nil), do: %{title: "", version: 1}

    @doc """
    Validation function for metadata - checks if metadata is in correct flat format.
    """
    def validate_metadata(%{title: _, version: _}), do: true
    def validate_metadata(_), do: false

    @doc """
    Migration function for address - handles missing nested fields.

    Old format may have incomplete nested structure.
    """
    def migrate_address(%{location: %{street: street, city: city}}) do
      %{street: street, city: city, country: nil}
    end

    def migrate_address(%{location: %{street: street}}) do
      %{street: street, city: nil, country: nil}
    end

    def migrate_address(%{street: _, city: _} = address), do: address
    def migrate_address(nil), do: %{street: nil, city: nil, country: nil}

    @doc """
    Validation function for address - checks if address is in correct flat format.
    """
    def validate_address(%{street: _, city: _}), do: true
    def validate_address(_), do: false
  end

  describe "RMX004_6A_T1: nested structure → flat map" do
    test "migrates nested URL structure to flat map" do
      # Setup: field with nested migration
      field_specs = [
        %Field{
          name: :audio,
          type: :map,
          migrate_fn: &TestSchema.migrate_audio/1,
          validate_fn: &TestSchema.validate_audio/1,
          opts: []
        }
      ]

      # Given: entity with old nested format
      data = %{
        id: "card1",
        audio: %{
          url: %{
            primary: "https://example.com/audio.mp3",
            format: "mp3"
          }
        }
      }

      # When: migration runs
      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # Then: nested structure flattened
      assert changed? == true

      assert migrated_data.audio == %{
               url: "https://example.com/audio.mp3",
               format: "mp3"
             }
    end

    test "preserves other fields during migration" do
      field_specs = [
        %Field{
          name: :audio,
          type: :map,
          migrate_fn: &TestSchema.migrate_audio/1,
          validate_fn: &TestSchema.validate_audio/1,
          opts: []
        }
      ]

      data = %{
        id: "card1",
        front: "Hello",
        audio: %{
          url: %{
            primary: "https://example.com/test.mp3",
            format: "mp3"
          }
        }
      }

      {migrated_data, _changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data.id == "card1"
      assert migrated_data.front == "Hello"
    end

    test "handles different audio formats in nested structure" do
      field_specs = [
        %Field{
          name: :audio,
          type: :map,
          migrate_fn: &TestSchema.migrate_audio/1,
          validate_fn: &TestSchema.validate_audio/1,
          opts: []
        }
      ]

      data = %{
        id: "card1",
        audio: %{
          url: %{
            primary: "https://example.com/audio.ogg",
            format: "ogg"
          }
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true

      assert migrated_data.audio == %{
               url: "https://example.com/audio.ogg",
               format: "ogg"
             }
    end
  end

  describe "RMX004_6A_T2: missing nested field" do
    test "handles missing nested fields gracefully" do
      field_specs = [
        %Field{
          name: :address,
          type: :map,
          migrate_fn: &TestSchema.migrate_address/1,
          validate_fn: &TestSchema.validate_address/1,
          opts: []
        }
      ]

      # Nested structure with incomplete data
      data = %{
        id: "user1",
        address: %{
          location: %{
            street: "123 Main St"
          }
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true

      assert migrated_data.address == %{
               street: "123 Main St",
               city: nil,
               country: nil
             }
    end

    test "nil value doesn't trigger migration (nil matches any type)" do
      field_specs = [
        %Field{
          name: :audio,
          type: :map,
          migrate_fn: &TestSchema.migrate_audio/1,
          validate_fn: &TestSchema.validate_audio/1,
          opts: []
        }
      ]

      data = %{id: "card1", audio: nil}

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # nil matches any type, so migration is not triggered
      assert changed? == false
      assert migrated_data.audio == nil
    end

    test "missing field remains missing" do
      field_specs = [
        %Field{
          name: :audio,
          type: :map,
          migrate_fn: &TestSchema.migrate_audio/1,
          validate_fn: &TestSchema.validate_audio/1,
          opts: []
        }
      ]

      # No audio field at all
      data = %{id: "card1"}

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == false
      assert Map.has_key?(migrated_data, :audio) == false
    end

    test "migration function can handle nil if explicitly called" do
      result = TestSchema.migrate_audio(nil)
      assert result == %{url: nil, format: "mp3"}
    end
  end

  describe "RMX004_6A_T3: deep nesting (3 levels)" do
    test "flattens three-level nested structure" do
      field_specs = [
        %Field{
          name: :config,
          type: :map,
          migrate_fn: &TestSchema.migrate_config/1,
          validate_fn: &TestSchema.validate_config/1,
          opts: []
        }
      ]

      # Three levels: config > settings > display
      data = %{
        id: "user1",
        config: %{
          settings: %{
            display: %{
              theme: "dark",
              size: 16
            }
          }
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true
      assert migrated_data.config == %{theme: "dark", size: 16}
    end

    test "handles different values in deep nesting" do
      field_specs = [
        %Field{
          name: :config,
          type: :map,
          migrate_fn: &TestSchema.migrate_config/1,
          validate_fn: &TestSchema.validate_config/1,
          opts: []
        }
      ]

      data = %{
        id: "user2",
        config: %{
          settings: %{
            display: %{
              theme: "light",
              size: 12
            }
          }
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true
      assert migrated_data.config == %{theme: "light", size: 12}
    end

    test "migration is idempotent for deep nesting" do
      field_specs = [
        %Field{
          name: :config,
          type: :map,
          migrate_fn: &TestSchema.migrate_config/1,
          validate_fn: &TestSchema.validate_config/1,
          opts: []
        }
      ]

      original = %{
        id: "user1",
        config: %{
          settings: %{
            display: %{theme: "dark", size: 16}
          }
        }
      }

      # First migration
      {migrated_once, changed1?} = Internal.migrate_entity(original, field_specs)
      assert changed1? == true

      # Second migration should be noop
      {migrated_twice, changed2?} = Internal.migrate_entity(migrated_once, field_specs)
      assert changed2? == false
      assert migrated_twice.config == migrated_once.config
    end
  end

  describe "RMX004_6A_T4: already migrated (flat → flat)" do
    test "passes through already-migrated flat map unchanged" do
      field_specs = [
        %Field{
          name: :audio,
          type: :map,
          migrate_fn: &TestSchema.migrate_audio/1,
          validate_fn: &TestSchema.validate_audio/1,
          opts: []
        }
      ]

      # Already in new flat format
      data = %{
        id: "card1",
        audio: %{
          url: "https://example.com/audio.mp3",
          format: "mp3"
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # No change, idempotent
      assert changed? == false
      assert migrated_data.audio == data.audio
    end

    test "migration is truly idempotent for flat structures" do
      field_specs = [
        %Field{
          name: :audio,
          type: :map,
          migrate_fn: &TestSchema.migrate_audio/1,
          validate_fn: &TestSchema.validate_audio/1,
          opts: []
        }
      ]

      original = %{
        id: "card1",
        audio: %{
          url: %{
            primary: "https://example.com/audio.mp3",
            format: "mp3"
          }
        }
      }

      # First migration
      {migrated_once, changed1?} = Internal.migrate_entity(original, field_specs)
      assert changed1? == true

      # Second migration (should be noop)
      {migrated_twice, changed2?} = Internal.migrate_entity(migrated_once, field_specs)
      assert changed2? == false
      assert migrated_twice == migrated_once
    end

    test "config already flat is not migrated" do
      field_specs = [
        %Field{
          name: :config,
          type: :map,
          migrate_fn: &TestSchema.migrate_config/1,
          validate_fn: &TestSchema.validate_config/1,
          opts: []
        }
      ]

      data = %{
        id: "user1",
        config: %{theme: "dark", size: 16}
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == false
      assert migrated_data.config == data.config
    end
  end

  describe "RMX004_6A_T5: partial nesting" do
    test "handles partially nested structure with version field" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: &TestSchema.migrate_metadata/1,
          validate_fn: &TestSchema.validate_metadata/1,
          opts: []
        }
      ]

      # Partial nesting: info is nested, version is at top level
      data = %{
        id: "doc1",
        metadata: %{
          info: %{
            title: "My Document"
          },
          version: 2
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true

      assert migrated_data.metadata == %{
               title: "My Document",
               version: 2
             }
    end

    test "handles nested info without version field" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: &TestSchema.migrate_metadata/1,
          validate_fn: &TestSchema.validate_metadata/1,
          opts: []
        }
      ]

      data = %{
        id: "doc1",
        metadata: %{
          info: %{
            title: "Another Document"
          }
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true

      assert migrated_data.metadata == %{
               title: "Another Document",
               version: 1
             }
    end

    test "multiple nested fields with different nesting levels" do
      field_specs = [
        %Field{
          name: :audio,
          type: :map,
          migrate_fn: &TestSchema.migrate_audio/1,
          validate_fn: &TestSchema.validate_audio/1,
          opts: []
        },
        %Field{
          name: :config,
          type: :map,
          migrate_fn: &TestSchema.migrate_config/1,
          validate_fn: &TestSchema.validate_config/1,
          opts: []
        }
      ]

      data = %{
        id: "card1",
        audio: %{
          url: %{
            primary: "https://example.com/audio.mp3",
            format: "mp3"
          }
        },
        config: %{
          settings: %{
            display: %{
              theme: "dark",
              size: 14
            }
          }
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true
      assert migrated_data.audio == %{url: "https://example.com/audio.mp3", format: "mp3"}
      assert migrated_data.config == %{theme: "dark", size: 14}
    end

    test "mixed migration states - one migrated, one not" do
      field_specs = [
        %Field{
          name: :audio,
          type: :map,
          migrate_fn: &TestSchema.migrate_audio/1,
          validate_fn: &TestSchema.validate_audio/1,
          opts: []
        },
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: &TestSchema.migrate_metadata/1,
          validate_fn: &TestSchema.validate_metadata/1,
          opts: []
        }
      ]

      data = %{
        id: "card1",
        # Already migrated
        audio: %{url: "https://example.com/audio.mp3", format: "mp3"},
        # Not yet migrated
        metadata: %{
          info: %{title: "Test"},
          version: 3
        }
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # Should detect change due to metadata
      assert changed? == true

      # Audio unchanged
      assert migrated_data.audio == data.audio

      # Metadata migrated
      assert migrated_data.metadata == %{title: "Test", version: 3}
    end
  end
end
