defmodule PState.EntityMigrationTest do
  use ExUnit.Case, async: true

  alias PState.Internal
  alias PState.Schema.Field

  describe "RMX003_3A_T1: migrate_entity with no migrations" do
    test "returns unchanged data when no fields need migration" do
      field_specs = [
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        },
        %Field{
          name: :back,
          type: :string,
          migrate_fn: nil,
          opts: []
        },
        %Field{
          name: :created_at,
          type: :integer,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        front: "Hello",
        back: "World",
        created_at: 1_234_567_890
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data == data
      assert changed? == false
    end

    test "returns unchanged data when fields match expected types with migrate_fn present" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        },
        %Field{
          name: :front,
          type: :string,
          migrate_fn: fn str -> String.upcase(str) end,
          opts: []
        }
      ]

      # All fields already match expected types
      data = %{
        metadata: %{notes: "test"},
        front: "hello"
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data == data
      assert changed? == false
    end

    test "returns unchanged data with empty field specs" do
      field_specs = []
      data = %{any: "data", some: "values"}

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data == data
      assert changed? == false
    end
  end

  describe "RMX003_3A_T2: migrate_entity with one field needing migration" do
    test "migrates single field from string to map" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        },
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        metadata: "old string value",
        front: "hello"
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data == %{
               metadata: %{notes: "old string value"},
               front: "hello"
             }

      assert changed? == true
    end

    test "migrates single field from list to map with refs" do
      field_specs = [
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: fn
            ids when is_list(ids) ->
              Map.new(ids, fn id -> {id, PState.Ref.new(:translation, id)} end)

            refs when is_map(refs) ->
              refs
          end,
          opts: []
        },
        %Field{
          name: :id,
          type: :string,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        translations: ["id1", "id2"],
        id: "card123"
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      expected_translations = %{
        "id1" => PState.Ref.new(:translation, "id1"),
        "id2" => PState.Ref.new(:translation, "id2")
      }

      assert migrated_data == %{
               translations: expected_translations,
               id: "card123"
             }

      assert changed? == true
    end

    test "migrates single field from string to ref" do
      field_specs = [
        %Field{
          name: :deck,
          type: :ref,
          migrate_fn: fn
            id when is_binary(id) -> PState.Ref.new(:base_deck, id)
            %PState.Ref{} = ref -> ref
          end,
          opts: []
        },
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        deck: "deck123",
        front: "hello"
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data == %{
               deck: PState.Ref.new(:base_deck, "deck123"),
               front: "hello"
             }

      assert changed? == true
    end
  end

  describe "RMX003_3A_T3: migrate_entity with multiple fields needing migration" do
    test "migrates multiple fields in a single pass" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        },
        %Field{
          name: :deck,
          type: :ref,
          migrate_fn: fn
            id when is_binary(id) -> PState.Ref.new(:base_deck, id)
            %PState.Ref{} = ref -> ref
          end,
          opts: []
        },
        %Field{
          name: :translations,
          type: :map,
          migrate_fn: fn
            ids when is_list(ids) ->
              Map.new(ids, fn id -> {id, PState.Ref.new(:translation, id)} end)

            refs when is_map(refs) ->
              refs
          end,
          opts: []
        }
      ]

      data = %{
        metadata: "old notes",
        deck: "deck123",
        translations: ["tr1", "tr2"]
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      expected_translations = %{
        "tr1" => PState.Ref.new(:translation, "tr1"),
        "tr2" => PState.Ref.new(:translation, "tr2")
      }

      assert migrated_data == %{
               metadata: %{notes: "old notes"},
               deck: PState.Ref.new(:base_deck, "deck123"),
               translations: expected_translations
             }

      assert changed? == true
    end

    test "migrates mix of fields needing and not needing migration" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        },
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        },
        %Field{
          name: :deck,
          type: :ref,
          migrate_fn: fn
            id when is_binary(id) -> PState.Ref.new(:base_deck, id)
            %PState.Ref{} = ref -> ref
          end,
          opts: []
        },
        %Field{
          name: :created_at,
          type: :integer,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        metadata: "old string",
        front: "Hello",
        deck: "deck123",
        created_at: 1_234_567_890
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data == %{
               metadata: %{notes: "old string"},
               front: "Hello",
               deck: PState.Ref.new(:base_deck, "deck123"),
               created_at: 1_234_567_890
             }

      assert changed? == true
    end
  end

  describe "RMX003_3A_T4: migrate_entity with already migrated data" do
    test "returns unchanged when all fields already in correct format" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        },
        %Field{
          name: :deck,
          type: :ref,
          migrate_fn: fn
            id when is_binary(id) -> PState.Ref.new(:base_deck, id)
            %PState.Ref{} = ref -> ref
          end,
          opts: []
        }
      ]

      # All fields already migrated
      data = %{
        metadata: %{notes: "already migrated"},
        deck: PState.Ref.new(:base_deck, "deck123")
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data == data
      assert changed? == false
    end

    test "idempotent migration returns same data on second pass" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        }
      ]

      # First migration
      data = %{metadata: "old string"}
      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true
      assert migrated_data == %{metadata: %{notes: "old string"}}

      # Second migration (idempotent)
      {migrated_again, changed_again?} = Internal.migrate_entity(migrated_data, field_specs)

      assert changed_again? == false
      assert migrated_again == migrated_data
    end
  end

  describe "RMX003_3A_T5: migrate_entity tracks changes correctly" do
    test "changed? is true when any field migrated" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        },
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        metadata: "old string",
        front: "hello"
      }

      {_migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true
    end

    test "changed? is false when no fields migrated" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        },
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        metadata: %{notes: "already map"},
        front: "hello"
      }

      {_migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == false
    end

    test "changed? is true when last field is migrated" do
      field_specs = [
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        },
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        }
      ]

      data = %{
        front: "hello",
        metadata: "old string"
      }

      {_migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true
    end

    test "changed? is true when first field is migrated" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        },
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        metadata: "old string",
        front: "hello"
      }

      {_migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert changed? == true
    end
  end

  describe "RMX003_3A_T6: migrate_entity preserves unmigrated fields" do
    test "preserves fields not in field specs" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        }
      ]

      data = %{
        metadata: "old string",
        front: "hello",
        back: "world",
        extra_field: "should remain",
        another: 123
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data == %{
               metadata: %{notes: "old string"},
               front: "hello",
               back: "world",
               extra_field: "should remain",
               another: 123
             }

      assert changed? == true
    end

    test "preserves fields without migrate_fn" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
          end,
          opts: []
        },
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        },
        %Field{
          name: :created_at,
          type: :integer,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        metadata: "old string",
        front: "hello",
        created_at: 1_234_567_890
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      assert migrated_data.front == "hello"
      assert migrated_data.created_at == 1_234_567_890
      assert changed? == true
    end

    test "handles nil values in unmigrated fields" do
      field_specs = [
        %Field{
          name: :metadata,
          type: :map,
          migrate_fn: fn
            str when is_binary(str) -> %{notes: str}
            map when is_map(map) -> map
            nil -> %{}
          end,
          opts: []
        },
        %Field{
          name: :front,
          type: :string,
          migrate_fn: nil,
          opts: []
        }
      ]

      data = %{
        metadata: nil,
        front: nil
      }

      {migrated_data, changed?} = Internal.migrate_entity(data, field_specs)

      # nil matches any type, so no migration needed
      assert migrated_data == %{metadata: nil, front: nil}
      assert changed? == false
    end
  end

  describe "RMX003_3A_T7: extract_entity_type with valid key" do
    test "extracts entity type from simple key" do
      assert Internal.extract_entity_type("base_card:123") == :base_card
    end

    test "extracts entity type from host_card key" do
      assert Internal.extract_entity_type("host_card:abc") == :host_card
    end

    test "extracts entity type from base_deck key" do
      assert Internal.extract_entity_type("base_deck:deck1") == :base_deck
    end

    test "extracts entity type from translation key" do
      assert Internal.extract_entity_type("translation:tr123") == :translation
    end

    test "extracts entity type with complex id containing special chars" do
      assert Internal.extract_entity_type("base_card:id-with-dashes-123") == :base_card
    end

    test "extracts entity type with numeric id" do
      assert Internal.extract_entity_type("host_card:999") == :host_card
    end
  end

  describe "RMX003_3A_T8: extract_entity_type with UUID" do
    test "extracts entity type from UUID key" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert Internal.extract_entity_type("base_card:#{uuid}") == :base_card
    end

    test "extracts entity type from different UUIDs" do
      uuid1 = "123e4567-e89b-12d3-a456-426614174000"
      uuid2 = "c73bcdcc-2669-4bf6-81d3-e4ae73fb11fd"

      assert Internal.extract_entity_type("host_card:#{uuid1}") == :host_card
      assert Internal.extract_entity_type("translation:#{uuid2}") == :translation
    end

    test "extracts entity type from UUID v4" do
      uuid = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
      assert Internal.extract_entity_type("base_deck:#{uuid}") == :base_deck
    end

    test "handles key with UUID containing only the first part after colon" do
      # Even if there are multiple colons, we only split on first
      key = "base_card:550e8400-e29b-41d4-a716-446655440000:extra"
      # This should extract just "base_card" and ignore everything after first colon
      assert Internal.extract_entity_type(key) == :base_card
    end
  end
end
