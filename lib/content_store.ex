defmodule ContentStore do
  @moduledoc """
  Main API coordinating EventStore and PState with Space (namespace) support.

  ContentStore is the orchestration layer that brings together immutable events
  from the EventStore and the mutable projection in PState. Each ContentStore
  instance operates within a specific Space, providing complete isolation for
  multi-tenancy and environment separation.

  Core workflows:

  1. **Command Execution**: Validate → Generate Events → Append → Apply
  2. **PState Rebuild**: Replay space-scoped events from scratch
  3. **Incremental Catchup**: Apply new events from space sequence
  4. **Checkpoint Tracking**: Track projection progress per space

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────┐
  │ ContentStore (Space-Scoped Orchestration)              │
  │ - space: Ramax.Space.t()                               │
  │ - execute/3: Command → Events (in space)               │
  │ - rebuild_pstate/2: Replay space events only           │
  │ - catchup_pstate/2: Apply new space events             │
  │ - get/update_checkpoint: Track space progress          │
  └─────────────────────────────────────────────────────────┘
                        │
          ┌─────────────┴─────────────┐
          ▼                           ▼
  ┌──────────────────┐          ┌──────────────────┐
  │ EventStore       │          │ PState           │
  │ (Immutable)      │          │ (Mutable View)   │
  │ space_id filter  │          │ space_id key     │
  │ events.db        │          │ pstate.db        │
  └──────────────────┘          └──────────────────┘
          │                           ▲
          │                           │
          └───────────────┬───────────┘
                          │
                  ┌───────▼────────┐
                  │ EventApplicator│
                  │ (Pure Functions)│
                  └────────────────┘
  ```

  ## Multi-Tenancy Usage

      # Customer A
      {:ok, acme_store} = ContentStore.new(
        space_name: "crm_acme",
        event_adapter: EventStore.Adapters.SQLite,
        event_opts: [database: "app.db"]
      )

      # Customer B (same database!)
      {:ok, widgets_store} = ContentStore.new(
        space_name: "crm_widgets",
        event_adapter: EventStore.Adapters.SQLite,
        event_opts: [database: "app.db"]
      )

      # Add contact to ACME (isolated)
      {:ok, [_], acme_store} = ContentStore.execute(
        acme_store,
        &CRM.Commands.add_contact/2,
        %{contact_id: "c1", name: "John"}
      )

      # Rebuild only ACME's projection (not Widgets!)
      acme_store = ContentStore.rebuild_pstate(acme_store)

  ## Basic Usage

      # Initialize ContentStore for a space
      {:ok, store} = ContentStore.new(
        space_name: "dev",
        event_adapter: EventStore.Adapters.ETS,
        pstate_adapter: PState.Adapters.ETS,
        root_key: "content:root"
      )

      # Execute a command
      params = %{deck_id: "spanish-101", name: "Spanish Basics"}
      {:ok, event_ids, store} = ContentStore.execute(
        store,
        &ContentStore.Command.create_deck/2,
        params
      )

      # Query PState
      {:ok, deck} = PState.fetch(store.pstate, "deck:spanish-101")

      # Rebuild PState from space events only
      store = ContentStore.rebuild_pstate(store)

      # Catchup PState with new space events
      {:ok, store, count} = ContentStore.catchup_pstate(store, 1000)

  ## References

  - ADR004: PState Materialization from Events
  - ADR005: Space Support Architecture Decision
  - RMX006: Event Application to PState Epic
  - RMX007: Space Support for Multi-Tenancy Epic
  """

  defstruct [:space, :event_store, :pstate, :config]

  @type t :: %__MODULE__{
          space: Ramax.Space.t(),
          event_store: EventStore.t(),
          pstate: PState.t(),
          config: map()
        }

  @doc """
  Create a new ContentStore instance.

  Initializes both the EventStore and PState with the specified adapters
  and options.

  ## Options

  - `:space_name` - Space name (required, e.g., "crm_acme")
  - `:event_adapter` - EventStore adapter module (default: `EventStore.Adapters.ETS`)
  - `:event_opts` - Options to pass to EventStore adapter (default: `[]`)
  - `:pstate_adapter` - PState adapter module (default: `PState.Adapters.ETS`)
  - `:pstate_opts` - Options to pass to PState adapter (default: `[]`)
  - `:root_key` - Root key for PState (default: `"content:root"`)
  - `:schema` - PState schema (optional)
  - `:event_applicator` - Module implementing event application logic (optional)
  - `:entity_id_extractor` - Function to extract entity ID from event payload (optional)
    - Receives event payload and returns entity ID string
    - Default: Returns root_key for all events
  - `:create_space_if_missing` - Auto-create space (default: true)

  ## Examples

      # In-memory store for development/testing
      {:ok, store} = ContentStore.new(space_name: "dev")

      # Custom adapters and options
      {:ok, store} = ContentStore.new(
        space_name: "crm_acme",
        event_adapter: EventStore.Adapters.SQLite,
        event_opts: [database: "events.db"],
        pstate_adapter: PState.Adapters.SQLite,
        pstate_opts: [path: "pstate.db"],
        root_key: "content:root"
      )

  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    # Require space_name
    space_name = Keyword.fetch!(opts, :space_name)

    # Store config for rebuild
    root_key = Keyword.get(opts, :root_key, "content:root")

    config = %{
      event_adapter: Keyword.get(opts, :event_adapter, EventStore.Adapters.ETS),
      event_opts: Keyword.get(opts, :event_opts, []),
      pstate_adapter: Keyword.get(opts, :pstate_adapter, PState.Adapters.ETS),
      pstate_opts: Keyword.get(opts, :pstate_opts, []),
      root_key: root_key,
      schema: Keyword.get(opts, :schema),
      event_applicator: Keyword.get(opts, :event_applicator),
      entity_id_extractor: Keyword.get(opts, :entity_id_extractor, fn _payload -> root_key end)
    }

    # Initialize event store (shared across spaces)
    {:ok, event_store} =
      EventStore.new(
        config.event_adapter,
        config.event_opts
      )

    # Get or create space
    case Ramax.Space.get_or_create(event_store, space_name) do
      {:ok, space, updated_event_store} ->
        # Initialize PState with space_id from space
        pstate =
          PState.new(
            config.root_key,
            space_id: space.space_id,
            adapter: config.pstate_adapter,
            adapter_opts: config.pstate_opts,
            schema: config.schema
          )

        store = %__MODULE__{
          space: space,
          event_store: updated_event_store,
          pstate: pstate,
          config: config
        }

        {:ok, store}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute a command: validate → generate events → append → apply.

  This is the main workflow for making changes to the system. Commands are
  pure functions that validate the current state and generate event specifications.
  Those events are then appended to the EventStore and applied to PState.

  The operation is atomic: either all events are appended and applied, or none are.

  ## Parameters

  - `store` - Current ContentStore instance
  - `command_fn` - Command function with signature `(PState.t(), params) -> {:ok, [event_spec]} | {:error, reason}`
  - `params` - Parameters to pass to the command function

  ## Returns

  - `{:ok, event_ids, updated_store}` - Command succeeded, events appended and applied
  - `{:error, reason}` - Command validation failed, no events appended

  ## Examples

      params = %{deck_id: "spanish-101", name: "Spanish Basics"}
      {:ok, [event_id], store} = ContentStore.execute(
        store,
        &ContentStore.Command.create_deck/2,
        params
      )

      # Query the result
      {:ok, deck} = PState.fetch(store.pstate, "deck:spanish-101")

      # Command validation errors
      {:error, {:deck_already_exists, "spanish-101"}} = ContentStore.execute(
        store,
        &ContentStore.Command.create_deck/2,
        params
      )

  """
  @spec execute(t(), function(), map()) ::
          {:ok, [EventStore.event_id()], t()} | {:error, term()}
  def execute(store, command_fn, params) do
    # 1. Run command to generate events
    case command_fn.(store.pstate, params) do
      {:ok, event_specs} ->
        # 2. Append events to event store (scoped to this space)
        {event_ids, updated_event_store} =
          append_events(
            store.event_store,
            store.space.space_id,
            event_specs,
            params,
            store.config.entity_id_extractor
          )

        # 3. Fetch events back with metadata
        events = fetch_events(updated_event_store, event_ids)

        # 4. Apply events to PState (if event_applicator configured)
        updated_pstate =
          if store.config.event_applicator do
            store.config.event_applicator.apply_events(store.pstate, events)
          else
            store.pstate
          end

        updated_store = %{store | event_store: updated_event_store, pstate: updated_pstate}

        {:ok, event_ids, updated_store}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Rebuild PState from scratch by replaying all events.

  Creates a fresh PState instance with the current schema and replays all events
  from the EventStore. This is useful for:

  - Schema migrations
  - Recovering from PState corruption
  - Testing event applicators
  - Creating new read models

  Events are streamed and applied in batches to handle large event logs efficiently.

  ## Options

  - `:batch_size` - Number of events to apply per batch (default: `1000`)
  - `:pstate_opts` - Options to pass to fresh PState instance

  ## Examples

      # Rebuild PState
      store = ContentStore.rebuild_pstate(store)

      # Rebuild with custom batch size
      store = ContentStore.rebuild_pstate(store, batch_size: 5000)

      # Verify rebuild produces same data
      {:ok, deck_before} = PState.fetch(store.pstate, "deck:spanish-101")
      store = ContentStore.rebuild_pstate(store)
      {:ok, deck_after} = PState.fetch(store.pstate, "deck:spanish-101")
      assert deck_before == deck_after

  """
  @spec rebuild_pstate(t(), keyword()) :: t()
  def rebuild_pstate(store, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 1000)

    IO.puts(
      "Rebuilding PState for space '#{store.space.space_name}' (ID: #{store.space.space_id})..."
    )

    # Create fresh PState using stored config with space_id from space
    # This will reuse the adapter table if it already exists (for shared tables)
    fresh_pstate =
      PState.new(
        store.config.root_key,
        space_id: store.space.space_id,
        adapter: store.config.pstate_adapter,
        adapter_opts: store.config.pstate_opts,
        schema: store.config.schema
      )

    # Clear only this space's data from the (potentially shared) table
    fresh_pstate = PState.clear_space(fresh_pstate)

    # Stream and apply only events from this space
    rebuilt_pstate =
      EventStore.stream_space_events(store.event_store, store.space.space_id,
        batch_size: batch_size
      )
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce(fresh_pstate, fn batch, ps ->
        IO.write(".")

        if store.config.event_applicator do
          store.config.event_applicator.apply_events(ps, batch)
        else
          ps
        end
      end)

    IO.puts("✓ Rebuild complete for space '#{store.space.space_name}'!")

    %{store | pstate: rebuilt_pstate}
  end

  @doc """
  Catch up PState with new events since a space sequence.

  Applies only events from this space that occurred after the specified
  space sequence number. This is useful for:

  - Incremental updates after downtime
  - Syncing read models
  - Processing event backlog

  ## Parameters

  - `store` - Current ContentStore instance
  - `from_space_sequence` - Only apply events with space_sequence > this value

  ## Returns

  - `{:ok, updated_store, count}` - PState caught up, returns number of events applied
  - Returns `{:ok, store, 0}` if already up-to-date

  ## Examples

      # Catchup from space sequence 1000
      {:ok, updated_store, events_count} = ContentStore.catchup_pstate(store, 1000)
      IO.puts("Applied \#{events_count} events")

      # Already up-to-date
      {:ok, latest_seq} = ContentStore.get_checkpoint(store)
      {:ok, same_store, 0} = ContentStore.catchup_pstate(store, latest_seq)

  """
  @spec catchup_pstate(t(), non_neg_integer()) :: {:ok, t(), non_neg_integer()}
  def catchup_pstate(store, from_space_sequence) do
    {:ok, latest_seq} =
      EventStore.get_space_latest_sequence(store.event_store, store.space.space_id)

    if from_space_sequence >= latest_seq do
      {:ok, store, 0}
    else
      {updated_pstate, count} =
        EventStore.stream_space_events(store.event_store, store.space.space_id,
          from_sequence: from_space_sequence
        )
        |> Enum.reduce({store.pstate, 0}, fn event, {ps, c} ->
          updated_ps =
            if store.config.event_applicator do
              store.config.event_applicator.apply_event(ps, event)
            else
              ps
            end

          {updated_ps, c + 1}
        end)

      {:ok, %{store | pstate: updated_pstate}, count}
    end
  end

  @doc """
  Get projection checkpoint for this space.

  Returns the last space_sequence that was processed for this space.
  Useful for tracking incremental catchup progress.

  ## Examples

      {:ok, checkpoint} = ContentStore.get_checkpoint(store)
      # checkpoint is the last space_sequence processed
  """
  @spec get_checkpoint(t()) :: {:ok, non_neg_integer()}
  def get_checkpoint(store) do
    # Delegate to adapter helper
    case store.event_store.adapter.get_projection_checkpoint(
           store.event_store.adapter_state,
           store.space.space_id
         ) do
      {:ok, checkpoint} -> {:ok, checkpoint}
      {:error, :not_found} -> {:ok, 0}
    end
  end

  @doc """
  Update projection checkpoint for this space.

  Stores the last space_sequence that was processed. This allows
  resuming catchup from where it left off.

  ## Examples

      :ok = ContentStore.update_checkpoint(store, 1500)
  """
  @spec update_checkpoint(t(), non_neg_integer()) :: :ok
  def update_checkpoint(store, space_sequence) do
    # Delegate to adapter helper
    store.event_store.adapter.update_projection_checkpoint(
      store.event_store.adapter_state,
      store.space.space_id,
      space_sequence
    )
  end

  # Private Helpers

  defp append_events(event_store, space_id, event_specs, params, entity_id_extractor) do
    Enum.reduce(event_specs, {[], event_store}, fn {event_type, payload}, {ids, es} ->
      entity_id = entity_id_extractor.(payload)

      {:ok, event_id, _space_sequence, new_es} =
        EventStore.append(
          es,
          space_id,
          entity_id,
          event_type,
          payload,
          correlation_id: params[:correlation_id]
        )

      {ids ++ [event_id], new_es}
    end)
  end

  defp fetch_events(event_store, event_ids) do
    Enum.map(event_ids, fn id ->
      {:ok, event} = EventStore.get_event(event_store, id)
      event
    end)
  end
end
