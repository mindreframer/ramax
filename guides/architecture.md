# Ramax Architecture Guide

> **System architecture, design decisions, and component interactions**

## Table of Contents

1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Core Components](#core-components)
4. [Space Architecture](#space-architecture)
5. [Data Flow](#data-flow)
6. [Storage Architecture](#storage-architecture)
7. [Design Decisions](#design-decisions)
8. [References](#references)

---

## Overview

Ramax is an **Event Sourcing and CQRS framework** for Elixir that provides:

- **EventStore**: Append-only event log with multiple adapter support
- **PState**: Materialized projections from events
- **ContentStore**: High-level API combining EventStore and PState
- **Spaces**: Multi-tenancy and environment isolation

### Design Philosophy

1. **Functional Core, Imperative Shell**: Pure functions for business logic, side effects at boundaries
2. **Immutability**: All state changes via events, data structures are immutable
3. **Pluggable Adapters**: Support multiple storage backends (SQLite, ETS, etc.)
4. **Space Isolation**: Complete multi-tenancy support at the architecture level

---

## System Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Application Layer                       │
│  (Commands, Queries, Business Logic)                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      ContentStore                            │
│  - Space management                                         │
│  - Command execution                                        │
│  - Event application                                        │
│  - Projection rebuilds                                      │
└─────────────────────────────────────────────────────────────┘
                    │                       │
          ┌─────────┴────────┐     ┌────────┴─────────┐
          ▼                  ▼     ▼                  ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│   EventStore     │  │     PState       │  │   Ramax.Space    │
│  - Append events │  │  - Projections   │  │  - Registry      │
│  - Stream events │  │  - Cache         │  │  - Metadata      │
│  - Sequences     │  │  - Access        │  │  - Lifecycle     │
└──────────────────┘  └──────────────────┘  └──────────────────┘
          │                  │                      │
          └──────────────────┼──────────────────────┘
                             ▼
                    ┌────────────────┐
                    │   Adapters     │
                    │  - SQLite      │
                    │  - ETS         │
                    │  - (Custom)    │
                    └────────────────┘
                             │
                             ▼
                    ┌────────────────┐
                    │    Storage     │
                    │  - Disk (DB)   │
                    │  - Memory      │
                    └────────────────┘
```

---

## Core Components

### 1. EventStore

**Responsibility**: Append-only event log with space support

```elixir
defmodule EventStore do
  @moduledoc """
  Event storage with multiple adapter support.

  Features:
  - Append events to specific spaces
  - Stream events by space
  - Global and per-space sequences
  - Causation/correlation tracking
  """
end
```

**Key Functions**:

- `append/6`: Append event to a space
- `stream_space_events/3`: Stream events for a specific space
- `get_space_latest_sequence/2`: Get latest sequence for a space
- `stream_all_events/2`: Stream all events across all spaces

**Sequence Numbers**:

- **Global (`event_id`)**: Monotonically increasing across ALL spaces
- **Space (`space_sequence`)**: Monotonically increasing within ONE space

```
Events Table:
┌──────────┬──────────┬────────────────┬───────────┬────────────┐
│ event_id │ space_id │ space_sequence │ entity_id │ event_type │
├──────────┼──────────┼────────────────┼───────────┼────────────┤
│     1    │    1     │       1        │  user-1   │  created   │
│     2    │    1     │       2        │  user-2   │  created   │
│     3    │    2     │       1        │  user-1   │  created   │
│     4    │    1     │       3        │  user-1   │  updated   │
│     5    │    2     │       2        │  user-2   │  created   │
└──────────┴──────────┴────────────────┴───────────┴────────────┘
                       ↑
              Independent per space
```

### 2. PState

**Responsibility**: Materialized projections with caching

```elixir
defmodule PState do
  @moduledoc """
  Projection state - materialized view from events.

  Features:
  - Space-scoped projections
  - In-memory cache
  - Schema validation
  - Adapter-based persistence
  """
end
```

**Key Functions**:

- `new/2`: Create PState for a space
- `fetch/2`: Get value by key
- `put/3`: Update value
- `delete/2`: Remove value
- Access protocol: `pstate["key"]`

**Storage Schema**:

```
PState Table:
┌──────────┬─────────────┬──────────────────────────┐
│ space_id │     key     │          value           │
├──────────┼─────────────┼──────────────────────────┤
│    1     │  user:u1    │  %{name: "Alice", ...}   │
│    1     │  user:u2    │  %{name: "Bob", ...}     │
│    2     │  user:u1    │  %{name: "Charlie", ...} │  ← Same key, different space
│    1     │  users:all  │  %{u1 => ..., u2 => ...} │
└──────────┴─────────────┴──────────────────────────┘
     ↑
  Composite key: (space_id, key)
```

### 3. ContentStore

**Responsibility**: High-level API combining EventStore and PState

```elixir
defmodule ContentStore do
  @moduledoc """
  Content store - combines EventStore and PState.

  Features:
  - Space-scoped operations
  - Command execution
  - Automatic event application
  - Projection rebuilds
  - Checkpoint tracking
  """

  defstruct [:space, :event_store, :pstate, :config]
end
```

**Key Functions**:

- `new/1`: Create ContentStore for a space
- `execute/3`: Execute command (validate → append → apply)
- `rebuild_pstate/2`: Rebuild projections from events
- `catchup_pstate/2`: Apply new events since checkpoint

**Command Execution Flow**:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. ContentStore.execute(store, command_fn, params)          │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Command validates current state (via PState)             │
│    command_fn(pstate, params) → {:ok, [event_specs]}        │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Append events to EventStore (in space)                   │
│    EventStore.append(store, space_id, entity_id, ...)       │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Apply events to PState (update projection)               │
│    event_applicator(pstate, event) → updated_pstate         │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. Return {:ok, [event_ids], updated_store}                 │
└─────────────────────────────────────────────────────────────┘
```

### 4. Ramax.Space

**Responsibility**: Space registry and lifecycle management

```elixir
defmodule Ramax.Space do
  @moduledoc """
  Space (namespace) management for multi-tenancy.

  Features:
  - Space creation and deletion
  - Name ↔ ID mapping
  - Metadata storage
  - Cascade deletion
  """

  defstruct [:space_id, :space_name, :metadata]
end
```

**Key Functions**:

- `get_or_create/3`: Find or create space by name
- `find_by_name/2`: Lookup by space_name
- `find_by_id/2`: Lookup by space_id
- `list_all/1`: List all spaces
- `delete/2`: Delete space and all data

---

## Space Architecture

### Space Isolation Model

Spaces provide **complete isolation** at the data layer:

```
                    ┌─────────────────────────────────┐
                    │      Application Layer           │
                    └─────────────────────────────────┘
                                  │
                ┌─────────────────┼─────────────────┐
                ▼                 ▼                 ▼
    ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
    │  ContentStore    │ │  ContentStore    │ │  ContentStore    │
    │  (crm_acme)      │ │  (crm_widgets)   │ │  (cms_staging)   │
    │                  │ │                  │ │                  │
    │  space_id: 1     │ │  space_id: 2     │ │  space_id: 3     │
    └──────────────────┘ └──────────────────┘ └──────────────────┘
            │                    │                    │
            │  events:1-100      │  events:1-50       │  events:1-500
            │  pstate:100 keys   │  pstate:50 keys    │  pstate:500 keys
            │                    │                    │
            └────────────────────┼────────────────────┘
                                 ▼
                    ┌─────────────────────────┐
                    │   Shared EventStore     │
                    │   Shared PState         │
                    └─────────────────────────┘
                                 │
                                 ▼
                    ┌─────────────────────────┐
                    │      Shared Storage     │
                    │                         │
                    │  events.db:            │
                    │    - space_id: 1 (100) │
                    │    - space_id: 2 (50)  │
                    │    - space_id: 3 (500) │
                    │                         │
                    │  pstate.db:            │
                    │    - space_id: 1 (100) │
                    │    - space_id: 2 (50)  │
                    │    - space_id: 3 (500) │
                    └─────────────────────────┘
```

### Space Registry

```
┌─────────────────────────────────────────────────────────┐
│                    Space Registry                        │
│                                                          │
│  ┌────────────┬────────────────┬──────────────────────┐ │
│  │ space_id   │ space_name     │ metadata             │ │
│  ├────────────┼────────────────┼──────────────────────┤ │
│  │     1      │ crm_acme       │ {customer: "acme"}   │ │
│  │     2      │ crm_widgets    │ {customer: "wdgt"}   │ │
│  │     3      │ cms_staging    │ {env: "staging"}     │ │
│  │     4      │ cms_production │ {env: "production"}  │ │
│  └────────────┴────────────────┴──────────────────────┘ │
└─────────────────────────────────────────────────────────┘
               │
               └──→ Maps space_name ↔ space_id
                    Used for space lookups and resolution
```

### Per-Space Sequences

```
┌────────────────────────────────────────────────────────────┐
│              Space Sequence Management                      │
│                                                             │
│  Space 1 (crm_acme):                                       │
│    ┌───────────────────────────────────────────────────┐  │
│    │ Event 1 → space_seq: 1, global_id: 1              │  │
│    │ Event 2 → space_seq: 2, global_id: 2              │  │
│    │ Event 3 → space_seq: 3, global_id: 4              │  │
│    └───────────────────────────────────────────────────┘  │
│                                                             │
│  Space 2 (crm_widgets):                                    │
│    ┌───────────────────────────────────────────────────┐  │
│    │ Event 1 → space_seq: 1, global_id: 3              │  │
│    │ Event 2 → space_seq: 2, global_id: 5              │  │
│    └───────────────────────────────────────────────────┘  │
│                                                             │
│  Note: space_sequence is independent per space             │
│        global event_id preserves total ordering            │
└────────────────────────────────────────────────────────────┘
```

### Selective Rebuild

```
┌──────────────────────────────────────────────────────────────┐
│           Selective Rebuild Architecture                      │
│                                                               │
│  Total Events: 1000                                          │
│    - Space 1: 100 events                                     │
│    - Space 2: 50 events                                      │
│    - Space 3: 850 events                                     │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ Rebuild Space 1 Only:                                  │  │
│  │                                                         │  │
│  │  SELECT * FROM events                                  │  │
│  │  WHERE space_id = 1                                    │  │
│  │  ORDER BY space_sequence                               │  │
│  │                                                         │  │
│  │  → Replays 100 events (not 1000!)                     │  │
│  │  → Spaces 2 and 3 unaffected                          │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                               │
│  Performance: 10x faster for 10% of events                   │
└──────────────────────────────────────────────────────────────┘
```

---

## Data Flow

### Write Path (Command Execution)

```
1. Application
   ↓ execute(store, command_fn, params)

2. ContentStore
   ↓ validates params
   ↓ calls command_fn(pstate, params)

3. Command Function
   ↓ validates business rules via PState
   ↓ returns {:ok, [event_specs]}

4. ContentStore
   ↓ appends events to EventStore

5. EventStore
   ↓ assigns event_id (global)
   ↓ assigns space_sequence (per space)
   ↓ writes to adapter

6. Adapter (SQLite/ETS)
   ↓ persists event
   ↓ increments sequences

7. ContentStore
   ↓ applies events to PState

8. EventApplicator
   ↓ updates projection
   ↓ invalidates cache

9. PState
   ↓ writes to adapter

10. Adapter
    ↓ persists projection

11. ContentStore
    ↓ returns {:ok, [event_ids], updated_store}
```

### Read Path (Query)

```
1. Application
   ↓ fetch(pstate, "key")

2. PState
   ↓ checks in-memory cache

3a. Cache Hit
    ↓ return {:ok, value}

3b. Cache Miss
    ↓ calls adapter.get(space_id, key)

4. Adapter
   ↓ reads from storage
   ↓ deserializes value

5. PState
   ↓ updates cache
   ↓ returns {:ok, value}
```

### Rebuild Path

```
1. Application
   ↓ rebuild_pstate(store)

2. ContentStore
   ↓ creates fresh PState for space

3. EventStore
   ↓ stream_space_events(space_id)
   ↓ returns lazy stream (only this space!)

4. ContentStore
   ↓ applies each event via event_applicator

5. EventApplicator
   ↓ updates PState projection

6. PState
   ↓ accumulates all updates

7. ContentStore
   ↓ persists updated PState
   ↓ returns rebuilt_store
```

---

## Storage Architecture

### SQLite Adapter Schema

```sql
-- Space Registry
CREATE TABLE spaces (
  space_id INTEGER PRIMARY KEY AUTOINCREMENT,
  space_name TEXT UNIQUE NOT NULL,
  created_at INTEGER NOT NULL,
  metadata TEXT
);

CREATE INDEX idx_spaces_name ON spaces(space_name);

-- Space Sequences
CREATE TABLE space_sequences (
  space_id INTEGER PRIMARY KEY,
  last_sequence INTEGER NOT NULL DEFAULT 0
);

-- Events
CREATE TABLE events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  space_id INTEGER NOT NULL,
  space_sequence INTEGER NOT NULL,
  entity_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload BLOB NOT NULL,
  timestamp INTEGER NOT NULL,
  causation_id INTEGER,
  correlation_id TEXT,
  created_at INTEGER
);

CREATE INDEX idx_events_space_seq ON events(space_id, space_sequence);
CREATE INDEX idx_events_space_entity ON events(space_id, entity_id, event_id);

-- PState Projections
CREATE TABLE pstate_entities (
  space_id INTEGER NOT NULL,
  key TEXT NOT NULL,
  value BLOB NOT NULL,
  updated_at INTEGER,
  PRIMARY KEY (space_id, key)
);

CREATE INDEX idx_pstate_space ON pstate_entities(space_id);

-- Projection Checkpoints
CREATE TABLE projection_checkpoints (
  space_id INTEGER PRIMARY KEY,
  last_event_id INTEGER NOT NULL,
  last_space_sequence INTEGER NOT NULL,
  updated_at INTEGER
);
```

### ETS Adapter Structure

```elixir
# EventStore ETS tables
:events             # ordered_set, {event_id, event}
:entity_index       # bag, {{entity_id, event_id}, event_id}
:space_index        # ordered_set, {{space_id, space_seq, event_id}, event_id}
:space_sequences    # set, {space_id, atomics_ref}
:event_counter      # atomics ref for global event_id

# PState ETS tables
:pstate_data        # set, {{space_id, key}, value}
```

---

## Design Decisions

### ADR003: Event Store Architecture

**Decision**: Use append-only event log with adapter pattern

**Rationale**:
- Event sourcing requires immutable event log
- Multiple storage backends needed (SQLite for persistence, ETS for testing)
- Adapter pattern provides flexibility

**Consequences**:
- ✅ Easy to add new storage backends
- ✅ Testing with in-memory adapter is fast
- ⚠️ Must implement each adapter carefully

### ADR004: PState Materialization from Events

**Decision**: Separate projection state (PState) from event log

**Rationale**:
- Read models optimized for queries
- Write models (events) optimized for appends
- CQRS pattern separation

**Consequences**:
- ✅ Fast queries without event replay
- ✅ Multiple projections from same events
- ⚠️ Projection must be rebuildable from events

### ADR005: Space Support for Multi-Tenancy

**Decision**: Implement spaces at the database schema level with composite keys

**Rationale**:
- Complete isolation required for multi-tenancy
- Selective rebuilds critical for performance
- Shared infrastructure simplifies operations

**Consequences**:
- ✅ Complete data isolation
- ✅ Efficient selective rebuilds
- ✅ Simple operational model
- ⚠️ Cannot share data between spaces
- ⚠️ All APIs require space_id

---

## References

### Architecture Decision Records (ADRs)

- **ADR003**: Event Store Architecture
- **ADR004**: PState Materialization from Events
- **ADR005**: Space Support for Multi-Tenancy

### Implementation Epics

- **RMX005**: Event Store Implementation
- **RMX006**: Event Application to PState
- **RMX007**: Space Support for Multi-Tenancy

### Guides

- **[Space Guide](spaces.md)**: Using spaces for multi-tenancy
- **[Migration Patterns](migration_patterns.md)**: Projection migration strategies
- **[Performance Tuning](performance_tuning.md)**: Optimization techniques

---

## Summary

Ramax architecture is built on these principles:

1. **Event Sourcing**: All state changes via immutable events
2. **CQRS**: Separate write (commands) and read (queries) models
3. **Spaces**: Complete multi-tenancy isolation
4. **Adapters**: Pluggable storage backends
5. **Functional Design**: Pure functions, immutable data

The **Space architecture** enables:

- Multi-tenant SaaS applications
- Environment separation (staging/production)
- Department/organization isolation
- Selective projection rebuilds
- Efficient shared infrastructure

For implementation details, see the [Space Guide](spaces.md).
