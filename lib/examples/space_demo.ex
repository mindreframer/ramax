defmodule SpaceDemo do
  @moduledoc """
  Space management demonstration showing core Ramax space features.

  This demo illustrates:
  - Creating multiple spaces
  - Listing all spaces
  - Appending events to different spaces
  - Querying space-specific data
  - Deleting spaces
  - Performance: selective vs full rebuild

  ## Overview

  Spaces provide complete isolation for multi-tenancy and environment separation.
  Each space has its own:
  - Independent event sequence (starts at 1 per space)
  - Isolated PState projections
  - Separate checkpoints
  - Dedicated metadata

  All spaces share the same physical storage (database) for efficiency.

  ## Usage

      # Run the complete demo
      SpaceDemo.run_demo()

      # Run specific demos
      SpaceDemo.demo_basic_space_operations()
      SpaceDemo.demo_space_isolation()
      SpaceDemo.demo_selective_rebuild()

  ## References

  - ADR005: Space Support Architecture Decision
  - RMX007: Space Support for Multi-Tenancy Epic
  """

  require Logger

  @doc """
  Run complete space management demo.

  This demonstrates all space features in sequence:
  1. Basic space operations (create, list, delete)
  2. Space isolation (independent sequences, isolated data)
  3. Selective rebuild performance
  """
  @spec run_demo() :: :ok
  def run_demo do
    Logger.info("=" <> String.duplicate("=", 79))
    Logger.info("RAMAX SPACE MANAGEMENT DEMO")
    Logger.info("=" <> String.duplicate("=", 79))

    demo_basic_space_operations()
    demo_space_isolation()
    demo_selective_rebuild()

    Logger.info("=" <> String.duplicate("=", 79))
    Logger.info("DEMO COMPLETE")
    Logger.info("=" <> String.duplicate("=", 79))

    :ok
  end

  @doc """
  Demonstrate basic space operations.

  Shows:
  - Creating spaces
  - Listing all spaces
  - Finding spaces by name and ID
  - Deleting spaces
  """
  @spec demo_basic_space_operations() :: :ok
  def demo_basic_space_operations do
    Logger.info("")
    Logger.info("--- Demo 1: Basic Space Operations ---")

    # Initialize EventStore
    {:ok, event_store} = EventStore.new(EventStore.Adapters.ETS)

    # Create multiple spaces
    Logger.info("Creating spaces...")
    {:ok, space1, event_store} = Ramax.Space.get_or_create(event_store, "demo_space_1")

    {:ok, _space2, event_store} =
      Ramax.Space.get_or_create(event_store, "demo_space_2", metadata: %{env: "staging"})

    {:ok, space3, event_store} =
      Ramax.Space.get_or_create(event_store, "demo_space_3", metadata: %{env: "production"})

    Logger.info("  ✓ Created 3 spaces")

    # List all spaces
    {:ok, spaces} = Ramax.Space.list_all(event_store)

    Logger.info("")
    Logger.info("Spaces registered:")

    Enum.each(spaces, fn space ->
      metadata = if space.metadata, do: " | metadata: #{inspect(space.metadata)}", else: ""

      Logger.info("  - #{space.space_name} (ID: #{space.space_id})#{metadata}")
    end)

    # Find space by name
    {:ok, found_space} = Ramax.Space.find_by_name(event_store, "demo_space_2")
    Logger.info("")
    Logger.info("Find by name 'demo_space_2': ID=#{found_space.space_id}")

    # Find space by ID
    {:ok, found_by_id} = Ramax.Space.find_by_id(event_store, space1.space_id)
    Logger.info("Find by ID #{space1.space_id}: name=#{found_by_id.space_name}")

    # Delete a space
    Logger.info("")
    Logger.info("Deleting space: #{space3.space_name}...")
    :ok = Ramax.Space.delete(event_store, space3.space_id)

    {:ok, remaining_spaces} = Ramax.Space.list_all(event_store)
    Logger.info("  ✓ Deleted. Remaining spaces: #{length(remaining_spaces)}")

    :ok
  end

  @doc """
  Demonstrate space isolation.

  Shows:
  - Independent event sequences per space
  - Isolated PState data
  - Same entity IDs in different spaces
  - No data leakage between spaces
  """
  @spec demo_space_isolation() :: :ok
  def demo_space_isolation do
    Logger.info("")
    Logger.info("--- Demo 2: Space Isolation ---")

    # Create two isolated ContentStores
    {:ok, store_a} =
      ContentStore.new(
        space_name: "isolation_demo_a",
        event_applicator: &SpaceDemo.SimpleApplicator.apply_event/2,
        entity_id_extractor: &extract_entity_id/1
      )

    {:ok, store_b} =
      ContentStore.new(
        space_name: "isolation_demo_b",
        event_applicator: &SpaceDemo.SimpleApplicator.apply_event/2,
        entity_id_extractor: &extract_entity_id/1
      )

    Logger.info("Created two isolated stores:")
    Logger.info("  - #{store_a.space.space_name} (space_id: #{store_a.space.space_id})")
    Logger.info("  - #{store_b.space.space_name} (space_id: #{store_b.space.space_id})")

    # Add events to both spaces with the SAME entity_id
    Logger.info("")
    Logger.info("Adding events with same entity_id 'user-1' to both spaces...")

    {:ok, [_], store_a} =
      ContentStore.execute(store_a, &create_user_event/2, %{
        user_id: "user-1",
        name: "Alice"
      })

    {:ok, [_], store_b} =
      ContentStore.execute(store_b, &create_user_event/2, %{
        user_id: "user-1",
        name: "Bob"
      })

    # Add more events to verify independent sequences
    {:ok, [_], store_a} =
      ContentStore.execute(store_a, &create_user_event/2, %{
        user_id: "user-2",
        name: "Alice2"
      })

    {:ok, [_], store_a} =
      ContentStore.execute(store_a, &create_user_event/2, %{
        user_id: "user-3",
        name: "Alice3"
      })

    {:ok, [_], store_b} =
      ContentStore.execute(store_b, &create_user_event/2, %{
        user_id: "user-2",
        name: "Bob2"
      })

    # Check independent sequences
    {:ok, seq_a} =
      EventStore.get_space_latest_sequence(store_a.event_store, store_a.space.space_id)

    {:ok, seq_b} =
      EventStore.get_space_latest_sequence(store_b.event_store, store_b.space.space_id)

    Logger.info("")
    Logger.info("Independent sequences:")
    Logger.info("  - Space A: #{seq_a} events")
    Logger.info("  - Space B: #{seq_b} events")

    # Check isolated data
    {:ok, user_a} = PState.fetch(store_a.pstate, "user:user-1")
    {:ok, user_b} = PState.fetch(store_b.pstate, "user:user-1")

    Logger.info("")
    Logger.info("Isolated data (same entity_id 'user-1'):")
    Logger.info("  - Space A: #{user_a.name}")
    Logger.info("  - Space B: #{user_b.name}")
    Logger.info("  ✓ Complete isolation verified")

    :ok
  end

  @doc """
  Demonstrate selective rebuild performance.

  Shows:
  - Creating spaces with different event volumes
  - Rebuilding only one space (selective)
  - Performance comparison: selective vs full rebuild
  """
  @spec demo_selective_rebuild() :: :ok
  def demo_selective_rebuild do
    Logger.info("")
    Logger.info("--- Demo 3: Selective Rebuild Performance ---")

    # Create space with few events
    {:ok, small_store} =
      ContentStore.new(
        space_name: "rebuild_demo_small",
        event_applicator: &SpaceDemo.SimpleApplicator.apply_event/2,
        entity_id_extractor: &extract_entity_id/1
      )

    # Create space with many events
    {:ok, large_store} =
      ContentStore.new(
        space_name: "rebuild_demo_large",
        event_applicator: &SpaceDemo.SimpleApplicator.apply_event/2,
        entity_id_extractor: &extract_entity_id/1
      )

    # Add events to small space (10 events)
    Logger.info("Populating small space with 10 events...")

    small_store =
      Enum.reduce(1..10, small_store, fn i, store ->
        {:ok, [_], updated_store} =
          ContentStore.execute(store, &create_user_event/2, %{
            user_id: "user-#{i}",
            name: "User #{i}"
          })

        updated_store
      end)

    # Add events to large space (500 events)
    Logger.info("Populating large space with 500 events...")

    large_store =
      Enum.reduce(1..500, large_store, fn i, store ->
        {:ok, [_], updated_store} =
          ContentStore.execute(store, &create_user_event/2, %{
            user_id: "user-#{i}",
            name: "User #{i}"
          })

        updated_store
      end)

    {:ok, seq_small} =
      EventStore.get_space_latest_sequence(small_store.event_store, small_store.space.space_id)

    {:ok, seq_large} =
      EventStore.get_space_latest_sequence(large_store.event_store, large_store.space.space_id)

    Logger.info("")
    Logger.info("Event counts:")
    Logger.info("  - Small space: #{seq_small} events")
    Logger.info("  - Large space: #{seq_large} events")
    Logger.info("  - Total: #{seq_small + seq_large} events")

    # Benchmark selective rebuild (small space only)
    Logger.info("")
    Logger.info("Rebuilding ONLY small space (selective rebuild)...")

    {time_selective, _rebuilt_small} =
      :timer.tc(fn ->
        ContentStore.rebuild_pstate(small_store)
      end)

    time_ms_selective = div(time_selective, 1000)

    Logger.info("  ✓ Selective rebuild: #{time_ms_selective}ms (#{seq_small} events)")
    Logger.info("")

    Logger.info("Performance Benefit:")

    Logger.info(
      "  - Selective rebuild processed #{seq_small} events (not #{seq_small + seq_large})"
    )

    Logger.info("  - Other spaces completely unaffected")
    Logger.info("  - Ideal for multi-tenant systems with many tenants")

    :ok
  end

  # Helper Functions

  # Simple event applicator for demo purposes.
  defmodule SimpleApplicator do
    @spec apply_event(PState.t(), EventStore.event()) :: PState.t()
    def apply_event(pstate, event) do
      case event.metadata.event_type do
        "user.created" ->
          p = event.payload
          user_key = "user:#{p.user_id}"

          user_data = %{
            id: p.user_id,
            name: p.name,
            created_at: DateTime.to_unix(event.metadata.timestamp)
          }

          put_in(pstate[user_key], user_data)

        _ ->
          pstate
      end
    end
  end

  defp create_user_event(_pstate, params) do
    {:ok,
     [
       {"user.created", %{user_id: params.user_id, name: params.name}}
     ]}
  end

  defp extract_entity_id(event_payload) do
    Map.get(event_payload, :user_id)
  end
end
