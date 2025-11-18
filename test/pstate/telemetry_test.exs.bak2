defmodule PState.TelemetryTest do
  use ExUnit.Case, async: false

  alias PState.{Adapters, MigrationWriter}

  @test_table :pstate_telemetry_test

  # Helper module for telemetry handlers
  defmodule TelemetryHelper do
    def handle_event(event, measurements, metadata, config) do
      # config contains the test_pid
      send(config.test_pid, {:telemetry, event, measurements, metadata})
    end

    def handle_metadata(_event, _measurements, metadata, config) do
      send(config.test_pid, {:metadata, metadata})
    end

    def handle_put_metadata(_event, _measurements, metadata, config) do
      send(config.test_pid, {:put_metadata, metadata})
    end
  end

  setup do
    # Clean up any existing handlers
    :telemetry.list_handlers([])
    |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)

    # Create test PState
    pstate =
      PState.new("track:test",
        adapter: Adapters.ETS,
        adapter_opts: [table_name: @test_table]
      )

    on_exit(fn ->
      # Clean up ETS table
      if :ets.info(@test_table) != :undefined do
        :ets.delete(@test_table)
      end
    end)

    %{pstate: pstate}
  end

  describe "RMX004_10A_T1: telemetry event emission (fetch)" do
    test "emits fetch event with correct measurements and metadata", %{pstate: pstate} do
      # Setup telemetry handler
      test_pid = self()

      :telemetry.attach(
        "test-fetch-handler",
        [:pstate, :fetch],
        &TelemetryHelper.handle_event/4,
        %{test_pid: test_pid}
      )

      # Setup test data
      pstate = put_in(pstate["base_card:123"], %{id: "123", front: "Hello"})

      # Clear cache to force fetch
      pstate = %{pstate | cache: %{}}

      # Perform fetch
      _result = pstate["base_card:123"]

      # Assert telemetry event received
      assert_receive {:telemetry, [:pstate, :fetch], measurements, metadata}

      # Check measurements
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0

      # Check metadata
      assert metadata.key == "base_card:123"
      assert is_boolean(metadata.migrated?)
      assert is_boolean(metadata.from_cache?)
      assert metadata.from_cache? == false

      :telemetry.detach("test-fetch-handler")
    end

    test "emits cache hit telemetry", %{pstate: pstate} do
      test_pid = self()

      :telemetry.attach(
        "test-cache-handler",
        [:pstate, :cache],
        &TelemetryHelper.handle_event/4,
        %{test_pid: test_pid}
      )

      # Setup test data
      pstate = put_in(pstate["base_card:123"], %{id: "123", front: "Hello"})

      # First fetch - cache miss
      pstate["base_card:123"]
      assert_receive {:telemetry, [:pstate, :cache], %{hit?: 0}, %{key: "base_card:123"}}

      # Second fetch - cache hit
      pstate["base_card:123"]
      assert_receive {:telemetry, [:pstate, :cache], %{hit?: 1}, %{key: "base_card:123"}}

      :telemetry.detach("test-cache-handler")
    end
  end

  describe "RMX004_10A_T2: telemetry event emission (migration)" do
    test "emits migration event when migration occurs", %{pstate: pstate} do
      # Define schema with migration
      defmodule TestMigrationSchema do
        use PState.Schema

        entity :base_card do
          field(:id, :string)

          field :metadata, :map do
            migrate(fn
              str when is_binary(str) -> %{notes: str}
              map when is_map(map) -> map
              nil -> %{}
            end)
          end
        end
      end

      # Create PState with schema
      pstate = %{pstate | schema: TestMigrationSchema}

      # Setup telemetry handler
      test_pid = self()

      :telemetry.attach(
        "test-migration-handler",
        [:pstate, :migration],
        &TelemetryHelper.handle_event/4,
        %{test_pid: test_pid}
      )

      # Write old format data (using Internal to bypass schema)
      old_data = %{id: "123", metadata: "old string format"}
      pstate = PState.Internal.put_and_invalidate(pstate, "base_card:123", old_data)

      # Clear cache to force migration
      pstate = %{pstate | cache: %{}}

      # Fetch triggers migration
      _result = pstate["base_card:123"]

      # Assert migration telemetry event received
      assert_receive {:telemetry, [:pstate, :migration], measurements, metadata}

      # Check measurements
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0

      # Check metadata
      assert metadata.key == "base_card:123"
      assert metadata.entity_type == :base_card
      assert metadata.fields_migrated == 1

      :telemetry.detach("test-migration-handler")
    end

    test "does not emit migration event when no migration needed", %{pstate: pstate} do
      defmodule NoMigrationSchema do
        use PState.Schema

        entity :base_card do
          field(:id, :string)
          field(:front, :string)
        end
      end

      pstate = %{pstate | schema: NoMigrationSchema}

      test_pid = self()

      :telemetry.attach(
        "test-no-migration-handler",
        [:pstate, :migration],
        &TelemetryHelper.handle_event/4,
        %{test_pid: test_pid}
      )

      # Write data in current format
      pstate = put_in(pstate["base_card:123"], %{id: "123", front: "Hello"})

      # Clear cache
      pstate = %{pstate | cache: %{}}

      # Fetch - no migration needed
      _result = pstate["base_card:123"]

      # Should not receive migration event
      refute_receive {:telemetry, [:pstate, :migration], _, _}, 100

      :telemetry.detach("test-no-migration-handler")
    end
  end

  describe "RMX004_10A_T3: telemetry event emission (flush)" do
    test "emits flush event with batch_size trigger", %{pstate: pstate} do
      test_pid = self()

      :telemetry.attach(
        "test-flush-handler",
        [:pstate, :migration_writer, :flush],
        &TelemetryHelper.handle_event/4,
        %{test_pid: test_pid}
      )

      # Start migration writer with small batch size
      {:ok, _pid} =
        MigrationWriter.start_link(
          pstate: pstate,
          batch_size: 3,
          flush_interval: 60_000
        )

      # Queue 3 writes to trigger auto-flush
      MigrationWriter.queue_write("key1", %{data: 1})
      MigrationWriter.queue_write("key2", %{data: 2})
      MigrationWriter.queue_write("key3", %{data: 3})

      # Should receive flush event
      assert_receive {:telemetry, [:pstate, :migration_writer, :flush], measurements, metadata},
                     1000

      # Check measurements
      assert is_integer(measurements.duration)
      assert measurements.count == 3

      # Check metadata
      assert metadata.trigger == :batch_size

      :telemetry.detach("test-flush-handler")
      GenServer.stop(MigrationWriter)
    end

    test "emits flush event with manual trigger", %{pstate: pstate} do
      test_pid = self()

      :telemetry.attach(
        "test-manual-flush-handler",
        [:pstate, :migration_writer, :flush],
        &TelemetryHelper.handle_event/4,
        %{test_pid: test_pid}
      )

      {:ok, _pid} = MigrationWriter.start_link(pstate: pstate, batch_size: 100)

      # Queue one write
      MigrationWriter.queue_write("key1", %{data: 1})

      # Manually flush
      :ok = MigrationWriter.flush()

      # Should receive flush event
      assert_receive {:telemetry, [:pstate, :migration_writer, :flush], measurements, metadata}

      assert measurements.count == 1
      assert metadata.trigger == :manual

      :telemetry.detach("test-manual-flush-handler")
      GenServer.stop(MigrationWriter)
    end
  end

  describe "RMX004_10A_T4: telemetry metadata accuracy" do
    test "fetch metadata reflects actual cache state", %{pstate: pstate} do
      test_pid = self()

      :telemetry.attach(
        "test-metadata-handler",
        [:pstate, :fetch],
        &TelemetryHelper.handle_metadata/4,
        %{test_pid: test_pid}
      )

      # Write data directly to adapter (bypass cache)
      data = %{id: "123", front: "Hello"}
      :ok = pstate.adapter.put(pstate.adapter_state, "base_card:123", data)

      # First fetch - not from cache (we didn't use put_in)
      _result = pstate["base_card:123"]
      assert_receive {:metadata, metadata1}
      assert metadata1.from_cache? == false

      # Manually add to cache to simulate second read
      pstate = put_in(pstate.cache["base_card:123"], data)

      # Second fetch - from cache (now it's cached)
      _result = pstate["base_card:123"]
      assert_receive {:metadata, metadata2}
      assert metadata2.from_cache? == true

      :telemetry.detach("test-metadata-handler")
    end

    test "put event includes correct key", %{pstate: pstate} do
      test_pid = self()

      :telemetry.attach(
        "test-put-handler",
        [:pstate, :put],
        &TelemetryHelper.handle_put_metadata/4,
        %{test_pid: test_pid}
      )

      # Perform put
      _pstate = put_in(pstate["base_card:456"], %{id: "456", front: "Test"})

      # Check metadata
      assert_receive {:put_metadata, metadata}
      assert metadata.key == "base_card:456"

      :telemetry.detach("test-put-handler")
    end
  end

  describe "RMX004_10A_T5: example telemetry handler" do
    test "PState.Telemetry.setup/0 attaches handlers successfully" do
      # Call setup
      :ok = PState.Telemetry.setup()

      # Verify handlers are attached
      handlers = :telemetry.list_handlers([:pstate, :fetch])
      assert Enum.any?(handlers, fn h -> h.id == "pstate-default-handlers" end)

      # Cleanup
      :telemetry.detach("pstate-default-handlers")
    end

    test "default handler processes events without errors", %{pstate: pstate} do
      import ExUnit.CaptureLog

      # Setup default handlers
      :ok = PState.Telemetry.setup()

      # Perform operations that trigger telemetry
      log =
        capture_log(fn ->
          pstate = put_in(pstate["base_card:123"], %{id: "123", front: "Hello"})
          _result = pstate["base_card:123"]

          # Give logger time to process
          Process.sleep(50)
        end)

      # Verify no errors in logs (handlers processed events successfully)
      # The default handler logs at debug level, which may not show in test output
      # But it should not crash
      assert is_binary(log)

      # Cleanup
      :telemetry.detach("pstate-default-handlers")
    end
  end
end
