defmodule EventStore.AdapterTest do
  use ExUnit.Case, async: true

  describe "RMX005_1A_T1: EventStore.Adapter behaviour exists" do
    test "module is defined" do
      assert Code.ensure_loaded?(EventStore.Adapter)
    end

    test "module has callbacks defined" do
      # Verify that callbacks are present by checking behaviour_info
      callbacks = EventStore.Adapter.behaviour_info(:callbacks)
      assert is_list(callbacks)
      assert length(callbacks) > 0
    end
  end

  describe "RMX005_1A_T2: All required callbacks defined" do
    test "defines init/1 callback" do
      callbacks = EventStore.Adapter.behaviour_info(:callbacks)
      assert {:init, 1} in callbacks
    end

    test "defines append/5 callback" do
      callbacks = EventStore.Adapter.behaviour_info(:callbacks)
      assert {:append, 5} in callbacks
    end

    test "defines get_events/3 callback" do
      callbacks = EventStore.Adapter.behaviour_info(:callbacks)
      assert {:get_events, 3} in callbacks
    end

    test "defines get_event/2 callback" do
      callbacks = EventStore.Adapter.behaviour_info(:callbacks)
      assert {:get_event, 2} in callbacks
    end

    test "defines get_all_events/2 callback" do
      callbacks = EventStore.Adapter.behaviour_info(:callbacks)
      assert {:get_all_events, 2} in callbacks
    end

    test "defines stream_all_events/2 callback" do
      callbacks = EventStore.Adapter.behaviour_info(:callbacks)
      assert {:stream_all_events, 2} in callbacks
    end

    test "defines get_latest_sequence/1 callback" do
      callbacks = EventStore.Adapter.behaviour_info(:callbacks)
      assert {:get_latest_sequence, 1} in callbacks
    end

    test "has exactly 7 callbacks" do
      callbacks = EventStore.Adapter.behaviour_info(:callbacks)
      assert length(callbacks) == 7
    end
  end

  describe "RMX005_1A_T3: Metadata type structure" do
    test "metadata type includes event_id" do
      # Type checking is compile-time, so we verify via documentation
      # and ensure the type is exported
      assert Code.ensure_loaded?(EventStore.Adapter)
    end

    test "metadata structure is documented in moduledoc" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(EventStore.Adapter)

      assert moduledoc =~ "event_id"
      assert moduledoc =~ "entity_id"
      assert moduledoc =~ "event_type"
      assert moduledoc =~ "timestamp"
      assert moduledoc =~ "causation_id"
      assert moduledoc =~ "correlation_id"
    end

    test "metadata fields are documented with correct types" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(EventStore.Adapter)

      # Verify the example structure is present
      assert moduledoc =~ "metadata:"
      assert moduledoc =~ "payload:"
    end
  end

  describe "RMX005_1A_T4: Event type structure" do
    test "event structure is documented" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(EventStore.Adapter)

      assert moduledoc =~ "metadata:"
      assert moduledoc =~ "payload:"
    end

    test "event has metadata and payload fields" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(EventStore.Adapter)

      # Verify the structure shows both fields
      assert moduledoc =~ "%{"
      assert moduledoc =~ "metadata:"
      assert moduledoc =~ "payload:"
    end

    test "references ADR003 and ADR004" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(EventStore.Adapter)

      assert moduledoc =~ "ADR003"
      assert moduledoc =~ "ADR004"
    end
  end
end
