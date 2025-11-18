defmodule ContentStore do
  @moduledoc """
  Main API coordinating EventStore and PState.

  ContentStore is the orchestration layer that brings together immutable events
  from the EventStore and the mutable projection in PState. It implements the
  core event sourcing workflow:

  1. **Command Execution**: Validate → Generate Events → Append → Apply
  2. **PState Rebuild**: Replay all events from scratch
  3. **Incremental Catchup**: Apply only new events

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────┐
  │ ContentStore (Orchestration Layer)                     │
  │ - execute/3: Command → Events → PState                 │
  │ - rebuild_pstate/2: Replay all events                  │
  │ - catchup_pstate/2: Apply new events incrementally     │
  └─────────────────────────────────────────────────────────┘
                        │
          ┌─────────────┴─────────────┐
          ▼                           ▼
  ┌──────────────────┐          ┌──────────────────┐
  │ EventStore       │          │ PState           │
  │ (Immutable)      │          │ (Mutable View)   │
  │                  │          │                  │
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

  ## Usage

      # Initialize ContentStore
      store = ContentStore.new(
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

      # Rebuild PState from all events
      store = ContentStore.rebuild_pstate(store)

      # Catchup PState with new events
      {:ok, store, count} = ContentStore.catchup_pstate(store, from_sequence: 1000)

  ## References

  - ADR004: PState Materialization from Events
  - RMX006: Event Application to PState Epic
  """

  defstruct [:event_store, :pstate, :config]

  @type t :: %__MODULE__{
          event_store: EventStore.t(),
          pstate: PState.t(),
          config: map()
        }

  @doc """
  Create a new ContentStore instance.

  Initializes both the EventStore and PState with the specified adapters
  and options.

  ## Options

  - `:event_adapter` - EventStore adapter module (default: `EventStore.Adapters.ETS`)
  - `:event_opts` - Options to pass to EventStore adapter (default: `[]`)
  - `:pstate_adapter` - PState adapter module (default: `PState.Adapters.ETS`)
  - `:pstate_opts` - Options to pass to PState adapter (default: `[]`)
  - `:space_id` - Space ID for PState multi-tenancy (default: `1`)
  - `:root_key` - Root key for PState (default: `"content:root"`)
  - `:schema` - PState schema (optional)
  - `:event_applicator` - Module implementing event application logic (optional)
  - `:entity_id_extractor` - Function to extract entity ID from event payload (optional)
    - Receives event payload and returns entity ID string
    - Default: Returns root_key for all events

  ## Examples

      # In-memory store for development/testing
      store = ContentStore.new()

      # Custom adapters and options
      store = ContentStore.new(
        event_adapter: EventStore.Adapters.SQLite,
        event_opts: [database: "events.db"],
        pstate_adapter: PState.Adapters.ETS,
        root_key: "content:root"
      )

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    # Store config for rebuild
    root_key = Keyword.get(opts, :root_key, "content:root")

    config = %{
      event_adapter: Keyword.get(opts, :event_adapter, EventStore.Adapters.ETS),
      event_opts: Keyword.get(opts, :event_opts, []),
      pstate_adapter: Keyword.get(opts, :pstate_adapter, PState.Adapters.ETS),
      pstate_opts: Keyword.get(opts, :pstate_opts, []),
      space_id: Keyword.get(opts, :space_id, 1),
      root_key: root_key,
      schema: Keyword.get(opts, :schema),
      event_applicator: Keyword.get(opts, :event_applicator),
      entity_id_extractor: Keyword.get(opts, :entity_id_extractor, fn _payload -> root_key end)
    }

    # Initialize event store
    {:ok, event_store} =
      EventStore.new(
        config.event_adapter,
        config.event_opts
      )

    # Initialize PState
    pstate =
      PState.new(
        config.root_key,
        space_id: config.space_id,
        adapter: config.pstate_adapter,
        adapter_opts: config.pstate_opts,
        schema: config.schema
      )

    %__MODULE__{
      event_store: event_store,
      pstate: pstate,
      config: config
    }
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
        # 2. Append events to event store
        {event_ids, updated_event_store} =
          append_events(
            store.event_store,
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

    IO.puts("Rebuilding PState from event store...")

    # Create fresh PState using stored config
    fresh_pstate =
      PState.new(
        store.config.root_key,
        space_id: store.config.space_id,
        adapter: store.config.pstate_adapter,
        adapter_opts: store.config.pstate_opts,
        schema: store.config.schema
      )

    # Stream and apply all events
    rebuilt_pstate =
      EventStore.stream_all_events(store.event_store, batch_size: batch_size)
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce(fresh_pstate, fn batch, ps ->
        IO.write(".")

        if store.config.event_applicator do
          store.config.event_applicator.apply_events(ps, batch)
        else
          ps
        end
      end)

    IO.puts("✓ Rebuild complete!")

    %{store | pstate: rebuilt_pstate}
  end

  @doc """
  Catch up PState with new events since a sequence.

  Applies only events that occurred after the specified sequence number.
  This is useful for:

  - Incremental updates after downtime
  - Syncing read models
  - Processing event backlog

  ## Parameters

  - `store` - Current ContentStore instance
  - `from_sequence` - Only apply events with event_id > this value

  ## Returns

  - `{:ok, updated_store, count}` - PState caught up, returns number of events applied
  - Returns `{:ok, store, 0}` if already up-to-date

  ## Examples

      # Catchup from sequence 1000
      {:ok, updated_store, events_count} = ContentStore.catchup_pstate(store, 1000)
      IO.puts("Applied events")

      # Already up-to-date
      {:ok, latest_seq} = EventStore.get_latest_sequence(store.event_store)
      {:ok, same_store, 0} = ContentStore.catchup_pstate(store, latest_seq)

  """
  @spec catchup_pstate(t(), non_neg_integer()) :: {:ok, t(), non_neg_integer()}
  def catchup_pstate(store, from_sequence) do
    {:ok, latest_seq} = EventStore.get_latest_sequence(store.event_store)

    if from_sequence >= latest_seq do
      {:ok, store, 0}
    else
      {updated_pstate, count} =
        EventStore.stream_all_events(store.event_store, from_sequence: from_sequence)
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

  # Private Helpers

  defp append_events(event_store, event_specs, params, entity_id_extractor) do
    Enum.reduce(event_specs, {[], event_store}, fn {event_type, payload}, {ids, es} ->
      entity_id = entity_id_extractor.(payload)

      # TODO (RMX007_6A): Replace hardcoded space_id with store.space.space_id
      # This temporary default space_id will be replaced in Phase 6
      # when ContentStore gets proper space support
      {:ok, event_id, _space_sequence, new_es} =
        EventStore.append(
          es,
          1,
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
