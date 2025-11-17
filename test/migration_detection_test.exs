defmodule PState.MigrationDetectionTest do
  use ExUnit.Case, async: true

  alias PState.Migration
  alias PState.Schema.Field

  describe "RMX003_2A_T1: needs_migration? with matching type" do
    test "returns false when value matches expected string type" do
      field = %Field{
        name: :title,
        type: :string,
        migrate_fn: fn str -> String.upcase(str) end,
        opts: []
      }

      # Value matches type - no migration needed
      assert Migration.needs_migration?("hello", field) == false
    end

    test "returns false when value matches expected integer type" do
      field = %Field{
        name: :count,
        type: :integer,
        migrate_fn: fn x -> x * 2 end,
        opts: []
      }

      # Value matches type - no migration needed
      assert Migration.needs_migration?(42, field) == false
    end

    test "returns false when value matches expected map type" do
      field = %Field{
        name: :metadata,
        type: :map,
        migrate_fn: fn
          str when is_binary(str) -> %{notes: str}
          map when is_map(map) -> map
        end,
        opts: []
      }

      # Value matches type - no migration needed
      assert Migration.needs_migration?(%{notes: "test"}, field) == false
    end

    test "returns false when value matches expected list type" do
      field = %Field{
        name: :tags,
        type: :list,
        migrate_fn: fn x -> x ++ [:migrated] end,
        opts: []
      }

      # Value matches type - no migration needed
      assert Migration.needs_migration?([:a, :b], field) == false
    end

    test "returns false when value matches expected ref type" do
      field = %Field{
        name: :owner,
        type: :ref,
        migrate_fn: fn id -> PState.Ref.new(:user, id) end,
        opts: []
      }

      # Value matches type - no migration needed
      ref = PState.Ref.new(:user, "123")
      assert Migration.needs_migration?(ref, field) == false
    end
  end

  describe "RMX003_2A_T2: needs_migration? with type mismatch" do
    test "returns true when string value doesn't match map type" do
      field = %Field{
        name: :metadata,
        type: :map,
        migrate_fn: fn
          str when is_binary(str) -> %{notes: str}
          map when is_map(map) -> map
        end,
        opts: []
      }

      # Type mismatch: string value, map expected
      assert Migration.needs_migration?("old string value", field) == true
    end

    test "returns true when integer value doesn't match string type" do
      field = %Field{
        name: :id,
        type: :string,
        migrate_fn: fn int -> Integer.to_string(int) end,
        opts: []
      }

      # Type mismatch: integer value, string expected
      assert Migration.needs_migration?(123, field) == true
    end

    test "returns true when list value doesn't match map type" do
      field = %Field{
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

      # Type mismatch: list value, map expected
      assert Migration.needs_migration?(["id1", "id2"], field) == true
    end

    test "returns true when string doesn't match ref type" do
      field = %Field{
        name: :owner,
        type: :ref,
        migrate_fn: fn id when is_binary(id) -> PState.Ref.new(:user, id) end,
        opts: []
      }

      # Type mismatch: string value, ref expected
      assert Migration.needs_migration?("user123", field) == true
    end

    test "returns true when map doesn't match string type" do
      field = %Field{
        name: :data,
        type: :string,
        migrate_fn: fn map -> inspect(map) end,
        opts: []
      }

      # Type mismatch: map value, string expected
      assert Migration.needs_migration?(%{key: "value"}, field) == true
    end
  end

  describe "RMX003_2A_T3: needs_migration? with nil migrate_fn" do
    test "returns false when migrate_fn is nil, regardless of type mismatch" do
      field = %Field{
        name: :title,
        type: :string,
        migrate_fn: nil,
        opts: []
      }

      # Even with type mismatch, no migrate_fn means no migration
      assert Migration.needs_migration?(123, field) == false
    end

    test "returns false when migrate_fn is nil with matching type" do
      field = %Field{
        name: :title,
        type: :string,
        migrate_fn: nil,
        opts: []
      }

      # No migrate_fn, type matches
      assert Migration.needs_migration?("hello", field) == false
    end

    test "returns false when migrate_fn is nil with mismatched map type" do
      field = %Field{
        name: :metadata,
        type: :map,
        migrate_fn: nil,
        opts: []
      }

      # Type mismatch but no migrate_fn
      assert Migration.needs_migration?("string value", field) == false
    end

    test "returns false when migrate_fn is nil for all types" do
      types_and_mismatched_values = [
        {:string, 123},
        {:integer, "text"},
        {:map, "text"},
        {:list, "text"},
        {:ref, "text"}
      ]

      for {type, value} <- types_and_mismatched_values do
        field = %Field{
          name: :test_field,
          type: type,
          migrate_fn: nil,
          opts: []
        }

        assert Migration.needs_migration?(value, field) == false,
               "Expected false for type #{type} with value #{inspect(value)}"
      end
    end
  end

  describe "RMX003_2A_T4: needs_migration? with nil value" do
    test "returns false when value is nil (nil matches any type)" do
      field = %Field{
        name: :metadata,
        type: :map,
        migrate_fn: fn
          str when is_binary(str) -> %{notes: str}
          map when is_map(map) -> map
          nil -> %{}
        end,
        opts: []
      }

      # Nil values always match, so no migration needed
      assert Migration.needs_migration?(nil, field) == false
    end

    test "returns false for nil value with string type" do
      field = %Field{
        name: :title,
        type: :string,
        migrate_fn: fn nil -> "" end,
        opts: []
      }

      # Nil matches string type
      assert Migration.needs_migration?(nil, field) == false
    end

    test "returns false for nil value with integer type" do
      field = %Field{
        name: :count,
        type: :integer,
        migrate_fn: fn nil -> 0 end,
        opts: []
      }

      # Nil matches integer type
      assert Migration.needs_migration?(nil, field) == false
    end

    test "returns false for nil value with list type" do
      field = %Field{
        name: :tags,
        type: :list,
        migrate_fn: fn nil -> [] end,
        opts: []
      }

      # Nil matches list type
      assert Migration.needs_migration?(nil, field) == false
    end

    test "returns false for nil value with ref type" do
      field = %Field{
        name: :owner,
        type: :ref,
        migrate_fn: fn nil -> nil end,
        opts: []
      }

      # Nil matches ref type
      assert Migration.needs_migration?(nil, field) == false
    end
  end

  describe "RMX003_2A_T5: needs_migration? with already migrated data" do
    test "returns false when data already in new format (map)" do
      field = %Field{
        name: :metadata,
        type: :map,
        migrate_fn: fn
          str when is_binary(str) -> %{notes: str}
          map when is_map(map) -> map
        end,
        opts: []
      }

      # Already in new format (map)
      migrated_data = %{notes: "already migrated", other: "data"}
      assert Migration.needs_migration?(migrated_data, field) == false
    end

    test "returns false when ref already in correct format" do
      field = %Field{
        name: :owner,
        type: :ref,
        migrate_fn: fn
          id when is_binary(id) -> PState.Ref.new(:user, id)
          %PState.Ref{} = ref -> ref
        end,
        opts: []
      }

      # Already a PState.Ref
      ref = PState.Ref.new(:user, "123")
      assert Migration.needs_migration?(ref, field) == false
    end

    test "returns false for idempotent migration (same format)" do
      field = %Field{
        name: :config,
        type: :map,
        migrate_fn: fn
          %{version: _} = map -> map
          other -> %{version: 1, data: other}
        end,
        opts: []
      }

      # Already has version key (migrated format)
      migrated_data = %{version: 2, data: "test", migrated: true}
      assert Migration.needs_migration?(migrated_data, field) == false
    end

    test "returns false when list-to-map migration already done" do
      field = %Field{
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

      # Already migrated from list to map
      migrated_refs = %{
        "id1" => PState.Ref.new(:translation, "id1"),
        "id2" => PState.Ref.new(:translation, "id2")
      }

      assert Migration.needs_migration?(migrated_refs, field) == false
    end

    test "returns true when old format still present" do
      field = %Field{
        name: :metadata,
        type: :map,
        migrate_fn: fn
          str when is_binary(str) -> %{notes: str}
          map when is_map(map) -> map
        end,
        opts: []
      }

      # Still in old format (string)
      old_data = "old string format"
      assert Migration.needs_migration?(old_data, field) == true
    end
  end
end
