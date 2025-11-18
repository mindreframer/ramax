# Ramax

**Event Sourcing and CQRS framework for Elixir with built-in multi-tenancy support.**

Ramax provides a lightweight, flexible event sourcing framework with:
- **EventStore**: Persistent event storage with multiple adapters (SQLite, ETS)
- **PState**: Materialized projections from events
- **ContentStore**: High-level API combining EventStore and PState
- **Spaces**: Complete multi-tenancy and environment isolation

## Table of Contents

- [Quick Start](#quick-start)
- [Multi-Tenancy with Spaces](#multi-tenancy-with-spaces)
- [Core Concepts](#core-concepts)
- [Examples](#examples)
- [Installation](#installation)
- [Documentation](#documentation)

## Quick Start

```elixir
# Create a ContentStore for a specific tenant/environment
{:ok, crm} = CRMExample.new_tenant("crm_acme")

# Execute commands (validates state, appends events, updates projections)
{:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@acme.com")

# Query current state
{:ok, contact} = CRMExample.get_contact(crm, "c1")
# => %{id: "c1", name: "John Doe", email: "john@acme.com", ...}

# Rebuild projections from events
crm = CRMExample.rebuild(crm)
```

## Multi-Tenancy with Spaces

**Spaces** provide complete isolation for multi-tenancy and environment separation. Each space has its own independent event sequence, isolated projections, and separate checkpoints—all while sharing the same physical database.

### Use Cases

1. **Multi-Tenant SaaS**: Isolate customer data (e.g., `crm_acme`, `crm_widgets`)
2. **Environment Separation**: Staging vs Production (e.g., `cms_staging`, `cms_production`)
3. **Department Isolation**: Separate departments in same org (e.g., `sales`, `support`)

### Architecture

```
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ crm_acme        │  │ crm_widgets     │  │ cms_staging     │
│ space_id: 1     │  │ space_id: 2     │  │ space_id: 3     │
│ Events: 1k      │  │ Events: 500     │  │ Events: 10k     │
└─────────────────┘  └─────────────────┘  └─────────────────┘
         │                   │                    │
         └───────────────────┼────────────────────┘
                             ▼
                   ┌────────────────┐
                   │ Shared Storage │
                   │  - events.db   │
                   │  - pstate.db   │
                   └────────────────┘
```

### Key Features

- **🔒 Complete Isolation**: No data leakage between spaces
- **🚀 Independent Sequences**: Each space has its own event sequence (starts at 1)
- **⚡ Selective Rebuild**: Rebuild one space without affecting others
- **📊 Checkpoint Tracking**: Per-space projection checkpoints
- **💾 Shared Storage**: Efficient single database for all spaces

### Multi-Tenant CRM Example

```elixir
# Create CRM for different customers (tenants)
{:ok, acme_crm} = CRMExample.new_tenant("crm_acme")
{:ok, widgets_crm} = CRMExample.new_tenant("crm_widgets")

# Add contact to ACME
{:ok, acme_crm} = CRMExample.add_contact(
  acme_crm,
  "c1",
  "John Doe",
  "john@acme.com"
)

# Add contact to Widgets (same ID, different space!)
{:ok, widgets_crm} = CRMExample.add_contact(
  widgets_crm,
  "c1",
  "Jane Smith",
  "jane@widgets.com"
)

# Each tenant sees only their own data
{:ok, john} = CRMExample.get_contact(acme_crm, "c1")
# => %{name: "John Doe", email: "john@acme.com", ...}

{:ok, jane} = CRMExample.get_contact(widgets_crm, "c1")
# => %{name: "Jane Smith", email: "jane@widgets.com", ...}

# Rebuild only ACME (Widgets completely unaffected)
acme_crm = CRMExample.rebuild(acme_crm)
```

### CMS Staging/Production Example

```elixir
# Create separate environments in same database
{:ok, staging} = CMSExample.new_environment("cms_staging")
{:ok, production} = CMSExample.new_environment("cms_production")

# Test in staging first
{:ok, staging} = CMSExample.publish_article(
  staging,
  "a1",
  "New Feature",
  "Testing new feature..."
)

# Verify in staging, then publish to production
{:ok, production} = CMSExample.publish_article(
  production,
  "a1",
  "New Feature",
  "Testing new feature..."
)

# Each environment is completely isolated
staging_count = CMSExample.get_event_count(staging)    # => 1
production_count = CMSExample.get_event_count(production)  # => 1
```

### Space Management

```elixir
# Initialize EventStore
{:ok, event_store} = EventStore.new(
  EventStore.Adapters.SQLite,
  database: "app.db"
)

# List all spaces
{:ok, spaces} = Ramax.Space.list_all(event_store)
# => [
#   %Ramax.Space{space_id: 1, space_name: "crm_acme"},
#   %Ramax.Space{space_id: 2, space_name: "crm_widgets"},
#   %Ramax.Space{space_id: 3, space_name: "cms_production"}
# ]

# Find space by name
{:ok, space} = Ramax.Space.find_by_name(event_store, "crm_acme")

# Delete a space (removes all events and projections)
:ok = Ramax.Space.delete(event_store, space.space_id)
```

### Performance Benefits

With spaces, you can rebuild projections for a single tenant without replaying all events:

```elixir
# Scenario: 100 tenants, each with 1k events = 100k total events

# WITHOUT spaces: Rebuild processes ALL 100k events
# WITH spaces: Rebuild one tenant processes only 1k events (100x faster!)

# Example with persistent storage
{:ok, acme_crm} = CRMExample.new_tenant(
  "crm_acme",
  event_adapter: EventStore.Adapters.SQLite,
  event_opts: [database: "crm.db"],
  pstate_adapter: PState.Adapters.SQLite,
  pstate_opts: [path: "crm.db"]
)

# Rebuild only ACME's data (other 99 tenants unaffected)
acme_crm = CRMExample.rebuild(acme_crm)
```

## Core Concepts

### EventStore

Append-only event log with support for multiple storage adapters:

```elixir
{:ok, event_store} = EventStore.new(EventStore.Adapters.SQLite, database: "events.db")

{:ok, event_id, space_seq, event_store} =
  EventStore.append(
    event_store,
    space_id,
    "contact-1",
    "contact.added",
    %{name: "John", email: "john@example.com"}
  )
```

### PState

Materialized view/projection built from events:

```elixir
pstate = PState.new("contacts", space_id: space_id)

# Fetch data
{:ok, contact} = PState.fetch(pstate, "contact:c1")

# Update data
pstate = put_in(pstate["contact:c1"], %{name: "John"})
```

### ContentStore

High-level API that combines EventStore and PState:

```elixir
{:ok, store} = ContentStore.new(
  space_name: "crm_acme",
  event_applicator: &MyApp.EventApplicator.apply_event/2,
  entity_id_extractor: &extract_entity_id/1
)

# Execute command (validates, appends events, updates projection)
{:ok, [event_id], store} = ContentStore.execute(
  store,
  &MyApp.Commands.add_contact/2,
  %{contact_id: "c1", name: "John", email: "john@example.com"}
)
```

## Examples

Ramax includes complete working examples:

- **`CRMExample`**: Multi-tenant CRM with contact management
- **`CMSExample`**: CMS with staging/production environments
- **`SpaceDemo`**: Space management and performance demonstrations
- **`FlashcardApp`**: Simple flashcard application showing basic patterns

Run examples:

```elixir
# Start IEx
iex -S mix

# Run CRM example
CRMExample.new_tenant("my_crm")

# Run CMS example
CMSExample.new_environment("my_cms")

# Run space management demo
SpaceDemo.run_demo()
```

## Installation

Add `ramax` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ramax, "~> 0.1.0"}
  ]
end
```

## Documentation

- **[Space Guide](guides/spaces.md)**: Comprehensive guide to using spaces for multi-tenancy
- **[Architecture Guide](guides/architecture.md)**: System architecture and design decisions
- **[Migration Patterns](guides/migration_patterns.md)**: Patterns for migrating projections
- **[Performance Tuning](guides/performance_tuning.md)**: Optimization strategies

API documentation is available at [HexDocs](https://hexdocs.pm/ramax).

## Architecture Decisions

This project follows Architecture Decision Records (ADRs):

- **ADR003**: Event Store Architecture
- **ADR004**: PState Materialization from Events
- **ADR005**: Space Support for Multi-Tenancy

## License

See [LICENSE](LICENSE) file for details.

## References

- **RMX007 Epic**: Space Support for Multi-Tenancy implementation
- **ADR005**: Space Support Architecture Decision Record
