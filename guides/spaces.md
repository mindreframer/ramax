# Ramax Spaces Guide

> **Comprehensive guide to using Spaces for multi-tenancy and environment isolation**

## Table of Contents

1. [Introduction](#introduction)
2. [What are Spaces?](#what-are-spaces)
3. [Core Concepts](#core-concepts)
4. [Use Cases](#use-cases)
5. [Getting Started](#getting-started)
6. [Space Management](#space-management)
7. [Building Multi-Tenant Applications](#building-multi-tenant-applications)
8. [Environment Separation](#environment-separation)
9. [Performance Considerations](#performance-considerations)
10. [Best Practices](#best-practices)
11. [Migration Guide](#migration-guide)
12. [Troubleshooting](#troubleshooting)

---

## Introduction

Ramax **Spaces** provide complete data isolation within a shared database infrastructure. Each space operates as an independent namespace with its own event sequence, projections, and checkpoints—enabling powerful multi-tenancy patterns while maintaining operational simplicity.

### Why Spaces?

Traditional multi-tenancy approaches often force a choice between:

- **Separate databases per tenant**: Maximum isolation but high operational overhead
- **Shared tables with tenant_id filtering**: Simple but prone to data leakage

**Spaces** offer the best of both worlds:

✅ Complete data isolation (like separate databases)
✅ Shared infrastructure (like tenant_id filtering)
✅ Independent event sequences per space
✅ Selective projection rebuilds
✅ Simple operations (single database)

---

## What are Spaces?

A **Space** is a logical namespace that provides complete isolation of:

- **Events**: Each space has its own event stream
- **Sequences**: Independent event numbering (starts at 1 per space)
- **Projections**: Separate materialized views (PState)
- **Checkpoints**: Per-space projection tracking

### Space Identity

Each space has two identifiers:

- **`space_id`**: Integer ID used internally for data storage (efficient)
- **`space_name`**: Human-readable name (e.g., `"crm_acme"`, `"cms_staging"`)

### Database Schema

Spaces are implemented at the schema level:

```sql
-- Space registry
CREATE TABLE spaces (
  space_id INTEGER PRIMARY KEY AUTOINCREMENT,
  space_name TEXT UNIQUE NOT NULL,
  created_at INTEGER NOT NULL,
  metadata TEXT
);

-- Events with space isolation
CREATE TABLE events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,  -- Global sequence
  space_id INTEGER NOT NULL,                   -- Space reference
  space_sequence INTEGER NOT NULL,             -- Per-space sequence
  entity_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload BLOB NOT NULL,
  -- ...
);

-- PState with space isolation
CREATE TABLE pstate_entities (
  space_id INTEGER NOT NULL,
  key TEXT NOT NULL,
  value BLOB NOT NULL,
  PRIMARY KEY (space_id, key)  -- Composite key
);

-- Per-space checkpoints
CREATE TABLE projection_checkpoints (
  space_id INTEGER PRIMARY KEY,
  last_event_id INTEGER NOT NULL,
  last_space_sequence INTEGER NOT NULL,
  updated_at INTEGER
);
```

---

## Core Concepts

### 1. Space ID vs Space Name

- **Space ID**: Internal integer identifier (used in data storage)
- **Space Name**: External string identifier (used in application code)

```elixir
# Create/find space by name
{:ok, space, event_store} = Ramax.Space.get_or_create(event_store, "crm_acme")

# space.space_id => 1 (assigned automatically)
# space.space_name => "crm_acme"
```

### 2. Global Sequence vs Space Sequence

Each event has **two** sequence numbers:

- **`event_id`** (global): Monotonically increasing across ALL spaces
- **`space_sequence`**: Monotonically increasing within ONE space

```elixir
# Space A: Append 3 events
event_id: 1, space_sequence: 1  (space A)
event_id: 2, space_sequence: 2  (space A)
event_id: 3, space_sequence: 3  (space A)

# Space B: Append 2 events
event_id: 4, space_sequence: 1  (space B)  # Note: space_sequence resets
event_id: 5, space_sequence: 2  (space B)
```

**Why both?**

- **Global sequence** (`event_id`): Preserves total event ordering, useful for global operations
- **Space sequence**: Enables selective rebuilds, per-space checkpoints

### 3. Space Isolation

Spaces provide **complete isolation**:

```elixir
# Same entity_id in different spaces = different entities
space_a = %{space_id: 1, space_name: "crm_acme"}
space_b = %{space_id: 2, space_name: "crm_widgets"}

# Both can have contact_id "c1" without conflict
acme_contact_c1 = %{id: "c1", name: "John", tenant: "ACME"}
widgets_contact_c1 = %{id: "c1", name: "Jane", tenant: "Widgets"}
```

### 4. Selective Rebuilds

Rebuild projections for one space without affecting others:

```elixir
# 100 tenants with 1k events each = 100k total events

# WITHOUT spaces: Rebuild all = 100k events replayed
ContentStore.rebuild_pstate(store)  # Replays ALL 100k events

# WITH spaces: Rebuild one tenant = 1k events replayed
ContentStore.rebuild_pstate(tenant_1_store)  # Replays only 1k events (100x faster!)
```

---

## Use Cases

### 1. Multi-Tenant SaaS

Isolate customer data in a shared database:

```elixir
# Customer A
{:ok, acme_crm} = CRMExample.new_tenant("crm_acme")

# Customer B
{:ok, widgets_crm} = CRMExample.new_tenant("crm_widgets")

# Customer C
{:ok, techco_crm} = CRMExample.new_tenant("crm_techco")

# Each tenant has complete data isolation
# Same database, separate spaces
```

**Benefits**:
- Simple operations (one database)
- Complete data isolation
- Independent backups/restores per tenant
- Selective rebuilds per tenant

### 2. Environment Separation (Staging/Production)

Separate staging and production in the same database:

```elixir
# Staging environment
{:ok, staging_cms} = CMSExample.new_environment("cms_staging")

# Production environment
{:ok, prod_cms} = CMSExample.new_environment("cms_production")

# Test in staging without affecting production
{:ok, staging_cms} = CMSExample.publish_article(
  staging_cms,
  "a1",
  "Experimental Feature",
  "Testing..."
)

# Production remains unaffected
```

**Benefits**:
- Easy environment cloning
- Test event sourcing without risk
- Simplified deployment pipelines

### 3. Department/Organization Isolation

Separate departments within an organization:

```elixir
{:ok, sales_crm} = CRMExample.new_tenant("org_sales")
{:ok, support_crm} = CRMExample.new_tenant("org_support")
{:ok, marketing_crm} = CRMExample.new_tenant("org_marketing")
```

### 4. Development/Testing

Create temporary spaces for testing:

```elixir
# Create test space
{:ok, test_store} = ContentStore.new(space_name: "test_#{:rand.uniform(1000)}")

# Run tests...

# Cleanup
Ramax.Space.delete(event_store, test_store.space.space_id)
```

---

## Getting Started

### Step 1: Create a Space-Aware ContentStore

```elixir
# Option 1: In-memory (ETS) - good for development/testing
{:ok, store} = ContentStore.new(
  space_name: "my_app",
  event_applicator: &MyApp.EventApplicator.apply_event/2,
  entity_id_extractor: &MyApp.extract_entity_id/1
)

# Option 2: Persistent (SQLite) - good for production
{:ok, store} = ContentStore.new(
  space_name: "my_app",
  event_adapter: EventStore.Adapters.SQLite,
  event_opts: [database: "app.db"],
  pstate_adapter: PState.Adapters.SQLite,
  pstate_opts: [path: "app.db"],
  event_applicator: &MyApp.EventApplicator.apply_event/2,
  entity_id_extractor: &MyApp.extract_entity_id/1
)
```

### Step 2: Execute Commands

Commands are automatically scoped to the space:

```elixir
{:ok, [event_id], store} = ContentStore.execute(
  store,
  &MyApp.Commands.create_user/2,
  %{user_id: "u1", name: "Alice"}
)

# Event is appended to this space only
# space_id is set automatically
```

### Step 3: Query Projections

PState is automatically scoped to the space:

```elixir
# Fetch user from this space
{:ok, user} = PState.fetch(store.pstate, "user:u1")
```

### Step 4: Rebuild if Needed

Rebuild projections for this space only:

```elixir
store = ContentStore.rebuild_pstate(store)
# Only replays events from this space
```

---

## Space Management

### Creating Spaces

Spaces are created automatically when you create a ContentStore:

```elixir
{:ok, store} = ContentStore.new(space_name: "my_space")
# Space "my_space" is created if it doesn't exist
```

Or manually:

```elixir
{:ok, event_store} = EventStore.new(EventStore.Adapters.SQLite, database: "app.db")

{:ok, space, event_store} = Ramax.Space.get_or_create(event_store, "my_space")

# With metadata
{:ok, space, event_store} = Ramax.Space.get_or_create(
  event_store,
  "my_space",
  metadata: %{env: "production", region: "us-east"}
)
```

### Listing Spaces

```elixir
{:ok, event_store} = EventStore.new(EventStore.Adapters.SQLite, database: "app.db")

{:ok, spaces} = Ramax.Space.list_all(event_store)

Enum.each(spaces, fn space ->
  IO.puts("#{space.space_name} (ID: #{space.space_id})")
end)
```

### Finding Spaces

```elixir
# Find by name
{:ok, space} = Ramax.Space.find_by_name(event_store, "crm_acme")

# Find by ID
{:ok, space} = Ramax.Space.find_by_id(event_store, 1)

# Handle not found
case Ramax.Space.find_by_name(event_store, "nonexistent") do
  {:ok, space} -> IO.puts("Found: #{space.space_name}")
  {:error, :not_found} -> IO.puts("Space not found")
end
```

### Deleting Spaces

⚠️ **WARNING**: This deletes ALL data for the space (events, projections, checkpoints)

```elixir
:ok = Ramax.Space.delete(event_store, space_id)
```

**What gets deleted:**
- All events in the space
- All PState projections for the space
- All checkpoints for the space
- Space metadata

**Not deleted:**
- Other spaces' data (complete isolation)

---

## Building Multi-Tenant Applications

### Pattern 1: Tenant-Scoped ContentStore

Each tenant gets its own ContentStore instance:

```elixir
defmodule MyApp.TenantManager do
  @moduledoc """
  Manages ContentStore instances per tenant.
  """

  # In production, use a registry or cache
  def get_tenant_store(tenant_name) do
    ContentStore.new(
      space_name: "tenant_#{tenant_name}",
      event_adapter: EventStore.Adapters.SQLite,
      event_opts: [database: "app.db"],
      pstate_adapter: PState.Adapters.SQLite,
      pstate_opts: [path: "app.db"],
      event_applicator: &MyApp.EventApplicator.apply_event/2,
      entity_id_extractor: &MyApp.extract_entity_id/1
    )
  end
end
```

### Pattern 2: Context-Based Tenant Resolution

```elixir
defmodule MyApp.Commands do
  def create_contact(tenant_name, params) do
    {:ok, store} = MyApp.TenantManager.get_tenant_store(tenant_name)

    ContentStore.execute(
      store,
      &MyApp.ContactCommands.create/2,
      params
    )
  end
end

# Usage
MyApp.Commands.create_contact("acme", %{
  contact_id: "c1",
  name: "John",
  email: "john@acme.com"
})
```

### Pattern 3: Web Request Tenant Resolution

```elixir
# In a Phoenix controller/plug
defmodule MyAppWeb.TenantPlug do
  def call(conn, _opts) do
    tenant = extract_tenant_from_subdomain(conn)
    {:ok, store} = MyApp.TenantManager.get_tenant_store(tenant)

    conn
    |> assign(:tenant, tenant)
    |> assign(:store, store)
  end

  defp extract_tenant_from_subdomain(conn) do
    # Extract tenant from subdomain (e.g., acme.myapp.com -> "acme")
    case conn.host |> String.split(".") do
      [tenant | _rest] -> tenant
      _ -> "default"
    end
  end
end

# In controller
defmodule MyAppWeb.ContactController do
  def create(conn, params) do
    store = conn.assigns.store

    case ContentStore.execute(store, &MyApp.Commands.create_contact/2, params) do
      {:ok, _, _store} ->
        json(conn, %{success: true})
      {:error, reason} ->
        json(conn, %{error: reason})
    end
  end
end
```

### Pattern 4: Tenant Data Isolation

```elixir
# Each tenant has completely isolated data
defmodule MyApp.ContactQueries do
  def list_contacts(tenant_name) do
    {:ok, store} = MyApp.TenantManager.get_tenant_store(tenant_name)

    # Fetch contacts from this tenant's space only
    case PState.fetch(store.pstate, "contacts:all") do
      {:ok, contacts} -> Map.values(contacts)
      :error -> []
    end
  end
end

# Usage
acme_contacts = MyApp.ContactQueries.list_contacts("acme")
widgets_contacts = MyApp.ContactQueries.list_contacts("widgets")

# Guaranteed no overlap even with same entity IDs
```

---

## Environment Separation

### Staging/Production Pattern

```elixir
defmodule MyApp.EnvironmentManager do
  def get_store(env) when env in ["staging", "production"] do
    ContentStore.new(
      space_name: "cms_#{env}",
      event_adapter: EventStore.Adapters.SQLite,
      event_opts: [database: "cms.db"],
      pstate_adapter: PState.Adapters.SQLite,
      pstate_opts: [path: "cms.db"],
      event_applicator: &MyApp.EventApplicator.apply_event/2,
      entity_id_extractor: &MyApp.extract_entity_id/1
    )
  end
end

# Promote staging to production
defmodule MyApp.Deployment do
  def promote_to_production(article_id) do
    # Read from staging
    {:ok, staging} = MyApp.EnvironmentManager.get_store("staging")
    {:ok, article} = PState.fetch(staging.pstate, "article:#{article_id}")

    # Publish to production
    {:ok, production} = MyApp.EnvironmentManager.get_store("production")
    ContentStore.execute(
      production,
      &MyApp.Commands.publish_article/2,
      article
    )
  end
end
```

---

## Performance Considerations

### 1. Selective Rebuilds

**Problem**: In a multi-tenant system with 100 tenants and 100k total events, rebuilding one tenant's projection shouldn't replay all 100k events.

**Solution**: Spaces enable selective rebuilds

```elixir
# Without spaces: Rebuild replays ALL events
ContentStore.rebuild_pstate(store)  # Replays 100k events

# With spaces: Rebuild replays only this space's events
ContentStore.rebuild_pstate(tenant_1_store)  # Replays 1k events
```

**Performance targets** (from RMX007 spec):

| Operation | Target |
|-----------|--------|
| Space creation | <10ms |
| Space lookup by name | <1ms |
| Space-scoped event append | <10ms |
| Selective rebuild (1k events) | <1s |
| Selective rebuild (10k events) | <5s |

### 2. Index Strategy

Spaces use composite indexes for efficient queries:

```sql
-- Fast space-scoped event queries
CREATE INDEX idx_events_space_seq ON events(space_id, space_sequence);

-- Fast entity lookup within space
CREATE INDEX idx_events_space_entity ON events(space_id, entity_id, event_id);

-- Fast PState lookups
CREATE INDEX idx_pstate_space ON pstate_entities(space_id);
```

### 3. Checkpoint Tracking

Each space maintains its own projection checkpoint:

```elixir
# Get checkpoint for a space
{:ok, checkpoint} = ContentStore.get_checkpoint(store)

# Update checkpoint after projection
:ok = ContentStore.update_checkpoint(store, space_sequence)

# Catchup only new events
{:ok, store, new_event_count} = ContentStore.catchup_pstate(store, from_sequence)
```

### 4. Memory Considerations

**ContentStore per tenant**:
- Each ContentStore instance has its own PState cache
- For 100 tenants, you might have 100 ContentStore instances in memory
- Consider using a GenServer pool or lazy loading

```elixir
defmodule MyApp.TenantStoreCache do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_or_create_store(tenant_name) do
    GenServer.call(__MODULE__, {:get_or_create, tenant_name})
  end

  def init(_) do
    {:ok, %{}}  # Map of tenant_name => store
  end

  def handle_call({:get_or_create, tenant_name}, _from, stores) do
    case Map.get(stores, tenant_name) do
      nil ->
        {:ok, store} = create_store(tenant_name)
        {:reply, {:ok, store}, Map.put(stores, tenant_name, store)}
      store ->
        {:reply, {:ok, store}, stores}
    end
  end

  defp create_store(tenant_name) do
    ContentStore.new(space_name: "tenant_#{tenant_name}", ...)
  end
end
```

---

## Best Practices

### 1. Space Naming Conventions

Use consistent, meaningful space names:

```elixir
# ✅ Good: Descriptive, consistent
"crm_acme"
"crm_widgets"
"cms_staging"
"cms_production"
"org_sales"
"org_support"

# ❌ Bad: Ambiguous, inconsistent
"space1"
"test"
"my_space"
```

### 2. Space Name Format

Recommended format: `{domain}_{identifier}`

```elixir
# Multi-tenant SaaS
"crm_#{customer_slug}"
"ecommerce_#{store_id}"

# Environment separation
"#{app_name}_#{environment}"

# Department isolation
"#{org_name}_#{department}"
```

### 3. Metadata Usage

Use space metadata for operational data:

```elixir
{:ok, space, event_store} = Ramax.Space.get_or_create(
  event_store,
  "crm_acme",
  metadata: %{
    customer_id: "cust_123",
    plan: "enterprise",
    region: "us-east",
    created_by: "admin@acme.com",
    tags: ["premium", "active"]
  }
)
```

### 4. Space Lifecycle Management

```elixir
defmodule MyApp.SpaceLifecycle do
  # Create space with validation
  def create_tenant_space(tenant_name, metadata) do
    with :ok <- validate_tenant_name(tenant_name),
         :ok <- validate_metadata(metadata),
         {:ok, space, event_store} <- Ramax.Space.get_or_create(
           event_store(),
           space_name(tenant_name),
           metadata: metadata
         ) do
      {:ok, space}
    end
  end

  # Archive space before deletion
  def archive_and_delete_space(space_id) do
    with {:ok, events} <- export_space_events(space_id),
         :ok <- archive_to_storage(space_id, events),
         :ok <- Ramax.Space.delete(event_store(), space_id) do
      :ok
    end
  end

  defp validate_tenant_name(name) do
    # Validate format, length, allowed characters
    if String.match?(name, ~r/^[a-z0-9_-]+$/) do
      :ok
    else
      {:error, :invalid_tenant_name}
    end
  end

  defp space_name(tenant_name), do: "tenant_#{tenant_name}"
end
```

### 5. Testing with Spaces

```elixir
defmodule MyApp.Test do
  setup do
    # Create unique test space
    test_space = "test_#{:rand.uniform(1_000_000)}"
    {:ok, store} = ContentStore.new(space_name: test_space)

    on_exit(fn ->
      # Cleanup test space
      Ramax.Space.delete(store.event_store, store.space.space_id)
    end)

    %{store: store, space_name: test_space}
  end

  test "user creation", %{store: store} do
    # Test with isolated space
    {:ok, _, _store} = ContentStore.execute(store, &create_user/2, %{...})
  end
end
```

### 6. Monitoring and Observability

Track space metrics:

```elixir
defmodule MyApp.SpaceMetrics do
  def get_space_stats(space_id) do
    {:ok, event_count} = EventStore.get_space_latest_sequence(event_store, space_id)
    {:ok, space} = Ramax.Space.find_by_id(event_store, space_id)
    {:ok, checkpoint} = get_checkpoint(space_id)

    %{
      space_name: space.space_name,
      event_count: event_count,
      checkpoint: checkpoint,
      created_at: space.created_at,
      metadata: space.metadata
    }
  end

  def list_space_stats() do
    {:ok, spaces} = Ramax.Space.list_all(event_store())
    Enum.map(spaces, &get_space_stats(&1.space_id))
  end
end
```

---

## Migration Guide

### Migrating from Non-Space Code

If you have existing Ramax code without spaces:

#### Before (No Spaces)

```elixir
# Old API (pre-RMX007)
{:ok, event_store} = EventStore.new(EventStore.Adapters.SQLite, database: "app.db")

{:ok, event_id, event_store} = EventStore.append(
  event_store,
  "user-1",
  "user.created",
  %{name: "Alice"}
)

pstate = PState.new("users")
```

#### After (With Spaces)

```elixir
# New API (post-RMX007)
{:ok, store} = ContentStore.new(
  space_name: "my_app",  # Required!
  event_adapter: EventStore.Adapters.SQLite,
  event_opts: [database: "app.db"]
)

# EventStore.append now requires space_id
{:ok, event_id, space_seq, event_store} = EventStore.append(
  event_store,
  space_id,  # Required!
  "user-1",
  "user.created",
  %{name: "Alice"}
)

# PState.new now requires space_id
pstate = PState.new("users", space_id: space_id)  # Required!
```

#### Migration Steps

1. **Choose a space name** for your existing data:
   ```elixir
   space_name = "default"  # or "app_production", etc.
   ```

2. **Update ContentStore initialization**:
   ```elixir
   # Add space_name to all ContentStore.new calls
   {:ok, store} = ContentStore.new(
     space_name: "default",
     # ... other options
   )
   ```

3. **Database migration** (if using SQLite adapter):
   ```sql
   -- Add space columns to existing tables
   ALTER TABLE events ADD COLUMN space_id INTEGER DEFAULT 1;
   ALTER TABLE events ADD COLUMN space_sequence INTEGER DEFAULT 0;
   ALTER TABLE pstate_entities ADD COLUMN space_id INTEGER DEFAULT 1;

   -- Create space registry
   CREATE TABLE spaces (
     space_id INTEGER PRIMARY KEY,
     space_name TEXT UNIQUE NOT NULL,
     created_at INTEGER NOT NULL,
     metadata TEXT
   );

   -- Insert default space
   INSERT INTO spaces (space_id, space_name, created_at)
   VALUES (1, 'default', strftime('%s', 'now'));

   -- Update sequences for existing events
   -- (Run a script to set space_sequence based on event_id per space)
   ```

4. **Update tests** to use spaces:
   ```elixir
   setup do
     {:ok, store} = ContentStore.new(
       space_name: "test_#{:rand.uniform(1000)}"
     )
     %{store: store}
   end
   ```

---

## Troubleshooting

### Problem: Space not found error

```elixir
{:error, :not_found} = Ramax.Space.find_by_name(event_store, "my_space")
```

**Solution**: Create the space first:

```elixir
{:ok, space, event_store} = Ramax.Space.get_or_create(event_store, "my_space")
```

### Problem: Data leaking between spaces

**Cause**: Incorrectly using the same space_id for multiple tenants.

**Solution**: Ensure each tenant has a unique space:

```elixir
# ✅ Correct: Each tenant gets unique space
{:ok, store_a} = ContentStore.new(space_name: "tenant_a")
{:ok, store_b} = ContentStore.new(space_name: "tenant_b")

# ❌ Incorrect: Reusing same space name
{:ok, store_a} = ContentStore.new(space_name: "shared")  # Don't do this!
{:ok, store_b} = ContentStore.new(space_name: "shared")  # Same space!
```

### Problem: Slow rebuild performance

**Cause**: Rebuilding the wrong space or rebuilding too many spaces.

**Solution**: Rebuild only the affected space:

```elixir
# ✅ Correct: Rebuild one tenant
{:ok, tenant_store} = ContentStore.new(space_name: "tenant_acme")
tenant_store = ContentStore.rebuild_pstate(tenant_store)  # Only replays this tenant's events

# ❌ Incorrect: Rebuilding all tenants
Enum.each(all_tenants, fn tenant ->
  rebuild_tenant(tenant)  # Unnecessarily rebuilds all tenants
end)
```

### Problem: Space sequence doesn't match event count

**Cause**: Space sequence starts at 1 per space, not globally.

**Diagnosis**:

```elixir
{:ok, seq} = EventStore.get_space_latest_sequence(event_store, space_id)
# seq represents the count of events in THIS space
```

**Expected behavior**: Each space has independent sequence starting at 1.

### Problem: Cannot delete space

**Error**: Foreign key constraint violation

**Cause**: Related data still exists (events, pstate, checkpoints)

**Solution**: The delete operation should cascade. Check adapter implementation:

```elixir
# Space.delete should handle cascade deletion
:ok = Ramax.Space.delete(event_store, space_id)
```

---

## Summary

**Spaces** enable powerful multi-tenancy and environment isolation patterns in Ramax:

✅ **Complete isolation** between spaces
✅ **Independent sequences** per space
✅ **Selective rebuilds** for performance
✅ **Shared infrastructure** for simplicity
✅ **Flexible use cases**: Multi-tenancy, staging/prod, departments

**Key Takeaways**:

1. Always specify `space_name` when creating ContentStore
2. Each space has independent event sequences
3. Use selective rebuilds for performance
4. Follow naming conventions for clarity
5. Leverage space metadata for operational data

**Next Steps**:

- Review [Architecture Guide](architecture.md) for system design
- Check [Performance Tuning](performance_tuning.md) for optimization
- See [Migration Patterns](migration_patterns.md) for projection updates

---

## References

- **ADR005**: Space Support Architecture Decision Record
- **RMX007**: Space Support for Multi-Tenancy Epic
- See `lib/examples/crm_example.ex` for complete multi-tenant example
- See `lib/examples/cms_example.ex` for staging/production example
- See `lib/examples/space_demo.ex` for space management demo
