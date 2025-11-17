# Migration Patterns Guide

This guide demonstrates common migration patterns for PState schema evolution.
All migrations are transparent and happen automatically on read.

## Overview

PState supports zero-downtime schema changes through transparent migrations:

1. **Read-time Migration**: Data is migrated when fetched
2. **Background Write-back**: Migrated data is written asynchronously
3. **Eventual Consistency**: Old format works until all data migrated

## Pattern 1: Collection Migration (List → Map)

**Use Case**: Converting a list of IDs to a map of ID → Ref for efficient lookups.

### Example

```elixir
defmodule MyApp.ContentSchema do
  use PState.Schema

  entity :base_deck do
    field :id, :string
    field :name, :string

    # Old format: cards: ["id1", "id2", "id3"]
    # New format: cards: %{"id1" => %Ref{}, "id2" => %Ref{}, ...}
    has_many :cards, ref: :base_card do
      migrate fn
        # Old: list of IDs
        ids when is_list(ids) ->
          Map.new(ids, fn id ->
            {id, PState.Ref.new(:base_card, id)}
          end)

        # Current: map of id → Ref
        refs when is_map(refs) ->
          refs

        # Handle nil/empty
        nil ->
          %{}
      end
    end
  end
end
```

### Migration Behavior

```elixir
# Old data in database:
%{
  id: "deck-uuid",
  name: "Spanish Basics",
  cards: ["card-1", "card-2", "card-3"]
}

# After first read (transparent migration):
%{
  id: "deck-uuid",
  name: "Spanish Basics",
  cards: %{
    "card-1" => %Ref{key: "base_card:card-1"},
    "card-2" => %Ref{key: "base_card:card-2"},
    "card-3" => %Ref{key: "base_card:card-3"}
  }
}

# Background writer queues write-back
# Next read: no migration needed, uses migrated format
```

### Best Practices

- ✅ Handle all old formats (list, nil)
- ✅ Keep migration idempotent (map → map returns unchanged)
- ✅ Use pattern matching for clear code
- ✅ Provide sensible defaults for nil

## Pattern 2: Nested Field Migration (Flatten Structure)

**Use Case**: Simplifying deeply nested structures for easier querying.

### Example

```elixir
defmodule MyApp.ContentSchema do
  use PState.Schema

  entity :base_card do
    field :id, :string
    field :front, :string

    # Old format: audio: %{url: %{primary: "...", format: "mp3"}}
    # New format: audio: %{url: "...", format: "mp3"}
    field :audio, :map do
      migrate fn
        # Old: nested structure
        %{url: %{primary: url, format: fmt}} ->
          %{url: url, format: fmt}

        # Old: nested with defaults
        %{url: %{primary: url}} ->
          %{url: url, format: "mp3"}

        # Current: flat structure
        %{url: _, format: _} = audio ->
          audio

        # Handle nil
        nil ->
          %{url: nil, format: "mp3"}
      end
    end
  end
end
```

### Migration Behavior

```elixir
# Old data:
%{
  id: "card-uuid",
  front: "Hello",
  audio: %{
    url: %{primary: "https://example.com/audio.mp3", format: "mp3"}
  }
}

# After migration:
%{
  id: "card-uuid",
  front: "Hello",
  audio: %{url: "https://example.com/audio.mp3", format: "mp3"}
}
```

### Best Practices

- ✅ Handle partial nesting (some fields missing)
- ✅ Provide sensible defaults
- ✅ Test deep nesting (3+ levels)
- ✅ Consider preserving extra fields if needed

## Pattern 3: Field Rename

**Use Case**: Renaming a field while maintaining backward compatibility.

### Example

```elixir
defmodule MyApp.ContentSchema do
  use PState.Schema

  entity :base_card do
    field :id, :string
    field :front, :string

    # Renamed from "notes" to "metadata"
    field :metadata, :map do
      migrate fn value, entity ->
        case value do
          # New field exists - use it
          meta when is_map(meta) ->
            meta

          # New field nil - read from old field
          nil ->
            # Read old "notes" field
            old_notes = Map.get(entity, :notes, "")
            %{notes: old_notes, tags: []}
        end
      end
    end
  end
end
```

### Migration Behavior

```elixir
# Old data (stored):
%{
  id: "card-uuid",
  front: "Hello",
  notes: "Important card"
}

# After first read:
%{
  id: "card-uuid",
  front: "Hello",
  notes: "Important card",  # Still present (not cleaned up)
  metadata: %{notes: "Important card", tags: []}
}

# After background write-back completes:
# Subsequent reads use metadata field directly
```

### Cleanup Strategy

**Option 1: Manual Cleanup** (Recommended)
```elixir
# Run migration script after all data migrated
defmodule MyApp.MigrationCleanup do
  def remove_old_notes_field do
    # Scan all base_card entities
    pstate
    |> PState.scan("base_card:")
    |> Enum.each(fn {key, entity} ->
      if Map.has_key?(entity, :notes) do
        cleaned = Map.delete(entity, :notes)
        put_in(pstate[key], cleaned)
      end
    end)
  end
end
```

**Option 2: After-Migrate Hook** (Future Enhancement)
```elixir
# Not implemented yet - future RMX phase
field :metadata, :map do
  migrate fn value, entity -> ... end

  after_migrate fn entity ->
    Map.delete(entity, :notes)
  end
end
```

### Best Practices

- ✅ Keep old field during migration period
- ✅ Document cleanup strategy
- ✅ Test with both old and new formats
- ❌ Don't delete old field in migration (breaks rollback)

## Pattern 4: Type Changes

**Use Case**: Changing field type while preserving data.

### Example

```elixir
defmodule MyApp.ContentSchema do
  use PState.Schema

  entity :base_card do
    field :id, :string

    # Old: tags as comma-separated string
    # New: tags as list
    field :tags, {:array, :string} do
      migrate fn
        # Old: string format
        tags when is_binary(tags) ->
          tags
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        # Current: list format
        tags when is_list(tags) ->
          tags

        # Handle nil
        nil ->
          []
      end
    end
  end
end
```

### Migration Behavior

```elixir
# Old data:
%{id: "card-uuid", tags: "spanish, verbs, beginner"}

# After migration:
%{id: "card-uuid", tags: ["spanish", "verbs", "beginner"]}
```

## Pattern 5: Adding Required Fields

**Use Case**: Adding a new required field to existing entities.

### Example

```elixir
defmodule MyApp.ContentSchema do
  use PState.Schema

  entity :base_card do
    field :id, :string
    field :front, :string

    # New required field: difficulty
    field :difficulty, :integer do
      migrate fn
        # Existing value
        diff when is_integer(diff) ->
          diff

        # New field - provide default
        nil ->
          1  # Default difficulty
      end
    end
  end
end
```

### Best Practices

- ✅ Always provide default for required fields
- ✅ Consider inferring from existing data
- ✅ Document default behavior

## Observability

All migrations emit telemetry events:

```elixir
# Migration occurred
[:pstate, :migration]
# Measurements: %{duration: microseconds}
# Metadata: %{key: string, entity_type: atom, fields_migrated: integer}

# Background write queued
[:pstate, :migration_writer, :queue]
# Measurements: %{queue_size: integer}
# Metadata: %{key: string}

# Background write flushed
[:pstate, :migration_writer, :flush]
# Measurements: %{duration: microseconds, count: integer}
# Metadata: %{trigger: :batch_size | :timer | :manual}
```

### Monitoring Migrations

```elixir
defmodule MyApp.MigrationMonitor do
  def setup do
    :telemetry.attach(
      "migration-monitor",
      [:pstate, :migration],
      &handle_migration/4,
      nil
    )
  end

  def handle_migration(_event, measurements, metadata, _config) do
    # Log migration for monitoring
    Logger.info("Migrated #{metadata.entity_type} #{metadata.key}: " <>
                "#{metadata.fields_migrated} fields in #{measurements.duration}μs")

    # Track migration progress
    MyApp.Metrics.increment("migrations.completed",
      tags: [entity_type: metadata.entity_type]
    )
  end
end
```

## Testing Migrations

```elixir
defmodule MyApp.MigrationTest do
  use ExUnit.Case

  describe "collection migration" do
    test "migrates list to map" do
      # Setup: old format data
      old_data = %{
        id: "deck-1",
        cards: ["card-1", "card-2"]
      }

      # Write old format
      pstate = put_in(pstate["base_deck:deck-1"], old_data)

      # Read triggers migration
      deck = pstate["base_deck:deck-1"]

      # Verify new format
      assert %{
        "card-1" => %PState.Ref{key: "base_card:card-1"},
        "card-2" => %PState.Ref{key: "base_card:card-2"}
      } = deck.cards
    end

    test "idempotent - map stays map" do
      # Already migrated data
      new_data = %{
        id: "deck-1",
        cards: %{
          "card-1" => PState.Ref.new(:base_card, "card-1")
        }
      }

      pstate = put_in(pstate["base_deck:deck-1"], new_data)
      deck = pstate["base_deck:deck-1"]

      # Should not change
      assert deck.cards == new_data.cards
    end
  end
end
```

## Performance Considerations

1. **First Read**: ~2ms (includes migration)
2. **Second Read**: ~0.5ms (no migration needed)
3. **Background Flush**: <50ms for 100 entities
4. **Eventual Consistency**: ~5 seconds (configurable)

### Optimization Tips

- Use `PState.preload/3` for batch loading
- Adjust `batch_size` and `flush_interval` for workload
- Monitor migration telemetry events
- Consider manual migration for large datasets

## Common Pitfalls

❌ **Don't**: Delete old fields in migration function
✅ **Do**: Keep old fields, clean up manually later

❌ **Don't**: Assume field always exists
✅ **Do**: Handle nil, provide defaults

❌ **Don't**: Mutate input data
✅ **Do**: Return new data structure

❌ **Don't**: Perform I/O in migration
✅ **Do**: Keep migrations pure functions

## Summary

- **Collection Migration**: List → Map for efficient lookups
- **Nested Migration**: Flatten for simpler queries
- **Field Rename**: Maintain backward compatibility
- **Type Changes**: Convert data types safely
- **Required Fields**: Always provide defaults

All migrations are:
- ✅ Zero-downtime
- ✅ Transparent (happen on read)
- ✅ Idempotent (safe to apply multiple times)
- ✅ Eventually consistent (background write-back)
- ✅ Observable (telemetry events)
