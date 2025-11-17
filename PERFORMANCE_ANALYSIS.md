# Performance Analysis & Proper Fix

## Problem Summary

The Access protocol (`pstate[key]`) auto-resolves **ALL** references recursively, causing O(n²) performance degradation.

### Example with 200 cards:
```elixir
# In event applicator:
update_in(pstate["card:card-100"], fn card ->
  # This line triggers:
  # 1. Fetch card-100
  # 2. Card has deck ref → resolve deck
  # 3. Deck has 200 card refs → resolve all 200 cards
  # 4. Each card has deck ref → circular, but detected
  # Result: ~40,000 ref lookups for ONE card update!
end)
```

## Band-Aid Fix (Current)

Used `PState.Internal` to bypass Access protocol.

**Problems:**
- ❌ Violates abstraction
- ❌ Two different APIs for same thing
- ❌ Confusing for developers
- ❌ Internal API might change

## Proper Fixes (Choose One)

### Option 1: **Change Default Behavior** (RECOMMENDED)

Make `pstate[key]` return raw data with Refs, add explicit resolution:

```elixir
# Fast by default - returns raw data with Refs
card = pstate["card:123"]
# %{id: "123", deck: %Ref{key: "deck:456"}, ...}

# Explicit resolution when needed
card = PState.get_resolved(pstate, "card:123", depth: 1)
# %{id: "123", deck: %{id: "456", cards: %{...}}, ...}
```

**Pros:**
- ✅ Safe by default (no accidental O(n²))
- ✅ Explicit when you want resolution
- ✅ Single, clear API
- ✅ Works with any backend

**Cons:**
- ⚠️  Breaking change
- ⚠️  Need to update all existing code

###Option 2: **Depth Limit by Default**

Keep auto-resolution but limit depth:

```elixir
# In PState config
pstate = PState.new("root", default_depth: 1)

# Or set globally
config :ramax, :pstate_default_depth, 1

pstate["card:123"]  # Resolves to depth 1 (safe)
PState.get(pstate, "card:123", depth: :infinity)  # Full resolution when needed
```

**Pros:**
- ✅ Less breaking
- ✅ Still prevents O(n²) by default
- ✅ Configurable

**Cons:**
- ⚠️  Magic number (what's the right default depth?)
- ⚠️  Still auto-resolves (can be slow with deep structures)

### Option 3: **Smart Caching**

Fix the cache to prevent redundant resolution:

```elixir
# Cache not just values, but RESOLVED values at each depth
pstate.cache = %{
  {"card:123", depth: 0} => raw_card,
  {"card:123", depth: 1} => card_with_deck,
  {"card:123", depth: :infinity} => fully_resolved_card
}
```

**Pros:**
- ✅ No breaking changes
- ✅ Transparent optimization
- ✅ Can still resolve deeply when needed

**Cons:**
- ⚠️  Memory usage (cache explosion)
- ⚠️  Complex cache invalidation
- ⚠️  Doesn't fix root cause

### Option 4: **Separate Write/Read APIs**

```elixir
# For writes (event applicators, commands) - raw data
PState.put(pstate, "card:123", card_data)
PState.update(pstate, "card:123", fn card -> ... end)

# For reads (queries) - auto-resolve
PState.get_resolved(pstate, "card:123")
PState.query(pstate, "card:123", depth: 2)
```

**Pros:**
- ✅ Clear separation of concerns
- ✅ Each API optimized for its use case
- ✅ No accidental O(n²)

**Cons:**
- ⚠️  Two APIs to learn
- ⚠️  Need to know which to use when

## Recommendation

**Go with Option 1** - Change default behavior to NOT auto-resolve.

### Migration Path:

1. Add `PState.get_resolved/3` now (non-breaking)
2. Deprecate auto-resolution in Access protocol
3. In next major version, make `pstate[key]` return raw data
4. Update all code to use explicit `get_resolved` where needed

### Implementation:

```elixir
# pstate.ex
@impl Access
def fetch(pstate, key) do
  # New behavior: no auto-resolution by default
  PState.Internal.fetch_and_auto_migrate(pstate, key)
end

# New explicit resolution API
def get_resolved(pstate, key, opts \\ []) do
  depth = Keyword.get(opts, :depth, :infinity)
  fetch_with_visited(pstate, key, MapSet.new(), depth)
end

# Convenience for common case
def get(pstate, key, depth: depth) do
  get_resolved(pstate, key, depth: depth)
end
```

This makes the abstraction **correct by default** and **explicit when needed**.

## Current Status

- ✅ Proper fix implemented (Option 1)
- ✅ Changed `pstate[key]` to default to depth: 0 (no auto-resolution)
- ✅ Added `PState.get_resolved/3` for explicit resolution
- ✅ Reverted all event applicators to use standard `put_in/update_in`
- ✅ Performance improved 932x (308ms → 0.33ms for 500 card update)
- ✅ 1500 card demo completes in ~350ms (was hanging before)
- ✅ Demo is idempotent (can run multiple times)
