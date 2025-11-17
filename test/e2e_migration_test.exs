defmodule PState.E2EMigrationTest do
  use ExUnit.Case, async: false

  alias PState
  alias PState.{Ref, Internal, MigrationWriter}
  alias PState.Adapters.{ETS, SQLite}
  alias Helpers.Value

  @moduledoc """
  Tests for RMX004_9A: End-to-End Migration Tests

  Comprehensive integration tests that verify the entire migration workflow:
  - Old data → read → migrate → background write → eventual consistency
  - Multiple migration patterns working together
  - Performance targets for production scenarios
  """

  # Simple test schema with type-checkable migrations
  defmodule TestSchema do
    use PState.Schema

    entity :base_card do
      field(:id, :string)
      field(:front, :string)
      field(:back, :string)

      # List → Map migration (type-checkable)
      field :translations, :map do
        migrate(fn
          ids when is_list(ids) ->
            Map.new(ids, fn id -> {id, Ref.new(:translation, id)} end)

          refs when is_map(refs) ->
            refs

          nil ->
            %{}
        end)
      end

      # String → Map migration (type-checkable)
      field :metadata, :map do
        migrate(fn
          str when is_binary(str) ->
            %{notes: str, created_at: nil}

          map when is_map(map) and not is_struct(map) ->
            map

          nil ->
            %{notes: "", created_at: nil}
        end)
      end
    end

    entity :base_deck do
      field(:id, :string)
      field(:name, :string)

      field :cards, :map do
        migrate(fn
          ids when is_list(ids) ->
            Map.new(ids, fn id -> {id, Ref.new(:base_card, id)} end)

          refs when is_map(refs) ->
            refs

          nil ->
            %{}
        end)
      end
    end

    entity :translation do
      field(:id, :string)
      field(:language, :string)
      field(:text, :string)
    end
  end

  defp create_pstate_with_schema(adapter \\ ETS, adapter_opts \\ []) do
    default_opts =
      case adapter do
        ETS -> [table_name: :"test_table_#{:erlang.unique_integer([:positive])}"]
        SQLite -> [path: ":memory:", table: "test_pstate_#{:erlang.unique_integer([:positive])}"]
      end

    opts = Keyword.merge(default_opts, adapter_opts)

    PState.new("root:test",
      adapter: adapter,
      adapter_opts: opts,
      schema: TestSchema
    )
  end

  defp start_migration_writer(pstate, opts \\ []) do
    flush_interval = Keyword.get(opts, :flush_interval, 100)
    batch_size = Keyword.get(opts, :batch_size, 100)

    try do
      GenServer.stop(MigrationWriter)
    catch
      :exit, _ -> :ok
    end

    Process.sleep(10)

    {:ok, pid} =
      MigrationWriter.start_link(
        pstate: pstate,
        flush_interval: flush_interval,
        batch_size: batch_size
      )

    pid
  end

  describe "RMX004_9A_T1: Complete workflow" do
    test "old data migrates on read and writes in background" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate, flush_interval: 100)

      old_card = %{
        id: "card1",
        front: "Hello",
        back: "Hola",
        translations: ["trans1", "trans2"],
        metadata: "old string notes"
      }

      pstate = put_in(pstate["base_card:card1"], old_card)
      pstate = %{pstate | cache: %{}}

      {:ok, migrated, _migrated?} = Internal.fetch_and_auto_migrate(pstate, "base_card:card1")

      assert is_map(migrated.translations)
      assert migrated.translations["trans1"] == %Ref{key: "translation:trans1"}
      assert migrated.metadata == %{notes: "old string notes", created_at: nil}

      Process.sleep(200)

      {:ok, stored} = pstate.adapter.get(pstate.adapter_state, "base_card:card1")
      assert is_map(stored[:translations])
      assert stored[:metadata][:notes] == "old string notes"

      GenServer.stop(writer_pid)
    end
  end

  describe "RMX004_9A_T2: Eventual consistency" do
    test "first read triggers migration, second read uses migrated data" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate, flush_interval: 100)

      old_card = %{
        id: "card1",
        front: "Test",
        translations: ["t1", "t2"],
        metadata: "notes"
      }

      pstate = put_in(pstate["base_card:card1"], old_card)
      pstate = %{pstate | cache: %{}}

      {time1_us, {:ok, result1, _}} =
        :timer.tc(fn -> Internal.fetch_and_auto_migrate(pstate, "base_card:card1") end)

      assert is_map(result1.translations)

      Process.sleep(200)
      pstate = %{pstate | cache: %{}}

      {time2_us, {:ok, result2, _}} =
        :timer.tc(fn -> Internal.fetch_and_auto_migrate(pstate, "base_card:card1") end)

      assert result1.translations == result2.translations
      assert result1.metadata == result2.metadata

      time1_ms = time1_us / 1000
      time2_ms = time2_us / 1000

      assert time1_ms < 5, "First read took #{time1_ms}ms, expected <5ms"
      assert time2_ms < 5, "Second read took #{time2_ms}ms, expected <5ms"

      GenServer.stop(writer_pid)
    end
  end

  describe "RMX004_9A_T3: Mixed format data" do
    test "handles entities in different migration states" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate)

      old_card = %{
        id: "card1",
        front: "Old",
        translations: ["t1"],
        metadata: "old notes"
      }

      new_card = %{
        id: "card2",
        front: "New",
        translations: %{"t2" => %Ref{key: "translation:t2"}},
        metadata: %{notes: "new notes", created_at: nil}
      }

      partial_card = %{
        id: "card3",
        front: "Partial",
        translations: %{"t3" => %Ref{key: "translation:t3"}},
        metadata: "partial notes"
      }

      pstate = put_in(pstate["base_card:card1"], old_card)
      pstate = put_in(pstate["base_card:card2"], new_card)
      pstate = put_in(pstate["base_card:card3"], partial_card)
      pstate = %{pstate | cache: %{}}

      {:ok, result1, _migrated?} = Internal.fetch_and_auto_migrate(pstate, "base_card:card1")
      {:ok, result2, _migrated?} = Internal.fetch_and_auto_migrate(pstate, "base_card:card2")
      {:ok, result3, _migrated?} = Internal.fetch_and_auto_migrate(pstate, "base_card:card3")

      assert is_map(result1.translations)
      assert is_map(result2.translations)
      assert is_map(result3.translations)

      assert result1.metadata.notes == "old notes"
      assert result2.metadata.notes == "new notes"
      assert result3.metadata.notes == "partial notes"

      GenServer.stop(writer_pid)
    end
  end

  describe "RMX004_9A_T4: Zero downtime schema change" do
    test "application continues working during schema migration" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate)

      old_card = %{
        id: "card1",
        front: "Test",
        translations: ["t1"],
        metadata: "notes"
      }

      pstate = put_in(pstate["base_card:card1"], old_card)

      {:ok, migrated, _migrated?} = Internal.fetch_and_auto_migrate(pstate, "base_card:card1")
      assert is_map(migrated.translations)

      new_card = %{
        id: "card2",
        front: "New",
        translations: %{"t2" => %Ref{key: "translation:t2"}},
        metadata: %{notes: "new", created_at: nil}
      }

      pstate = put_in(pstate["base_card:card2"], new_card)
      pstate = %{pstate | cache: %{}}

      {:ok, still_works, _migrated?} = Internal.fetch_and_auto_migrate(pstate, "base_card:card1")
      assert is_map(still_works.translations)

      {:ok, new_data, _migrated?} = Internal.fetch_and_auto_migrate(pstate, "base_card:card2")
      assert new_data.translations["t2"] == %Ref{key: "translation:t2"}

      GenServer.stop(writer_pid)
    end
  end

  describe "RMX004_9A_T5: Helpers.Value integration" do
    test "Value.get works with migrated data" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate)

      old_card = %{
        id: "card1",
        front: "Hello",
        translations: ["t1"],
        metadata: "my notes"
      }

      pstate = put_in(pstate["base_card:card1"], old_card)
      pstate = %{pstate | cache: %{}}

      front = Value.get(pstate, "base_card:card1.front")
      assert front == "Hello"

      notes = Value.get(pstate, "base_card:card1.metadata.notes")
      assert notes == "my notes"

      GenServer.stop(writer_pid)
    end

    test "Value.insert works with migrated entities" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate)

      pstate = Value.insert(pstate, "base_card:card1.front", "Front text")
      pstate = Value.insert(pstate, "base_card:card1.back", "Back text")
      pstate = Value.insert(pstate, "base_card:card1.id", "card1")

      pstate =
        Value.insert(pstate, "base_card:card1.metadata", %{
          "notes" => "inserted",
          "created_at" => nil
        })

      card = Value.get(pstate, "base_card:card1")
      assert card["front"] == "Front text"
      # Value.get returns data with string keys, metadata has string keys too
      assert is_map(card["metadata"])
      # Could be string or atom keys depending on how it was stored
      notes = card["metadata"]["notes"] || card["metadata"][:notes]
      assert notes == "inserted"

      GenServer.stop(writer_pid)
    end
  end

  describe "RMX004_9A_T6: Per-track migration" do
    test "migrates 1500 cards efficiently" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate, batch_size: 100, flush_interval: 1000)

      cards =
        Enum.map(1..1500, fn i ->
          {
            "base_card:card#{i}",
            %{
              id: "card#{i}",
              front: "Front #{i}",
              back: "Back #{i}",
              translations: ["t#{i}"],
              metadata: "notes #{i}"
            }
          }
        end)

      pstate =
        Enum.reduce(cards, pstate, fn {key, card}, acc ->
          put_in(acc[key], card)
        end)

      pstate = %{pstate | cache: %{}}

      {duration_us, results} =
        :timer.tc(fn ->
          Enum.map(1..1500, fn i ->
            {:ok, migrated, _migrated?} =
              Internal.fetch_and_auto_migrate(pstate, "base_card:card#{i}")

            migrated
          end)
        end)

      duration_ms = duration_us / 1000

      assert length(results) == 1500

      Enum.each(results, fn card ->
        assert is_map(card.translations)
        assert is_map(card.metadata)
      end)

      assert duration_ms < 3000,
             "Migration of 1500 cards took #{duration_ms}ms, expected <3000ms"

      Process.sleep(500)
      MigrationWriter.flush()
      Process.sleep(100)

      {:ok, stored1} = pstate.adapter.get(pstate.adapter_state, "base_card:card1")
      {:ok, stored500} = pstate.adapter.get(pstate.adapter_state, "base_card:card500")
      {:ok, stored1500} = pstate.adapter.get(pstate.adapter_state, "base_card:card1500")

      assert is_map(stored1[:translations])
      assert is_map(stored500[:translations])
      assert is_map(stored1500[:translations])

      GenServer.stop(writer_pid)
    end
  end

  describe "RMX004_9A_T7: SQLite persistence" do
    @tag :tmp_dir
    test "data persists across database restarts (without Refs)", %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "test_migration.db")

      # First session: Write data
      pstate1 = create_pstate_with_schema(SQLite, path: db_path, table: "pstate_test")

      # Write simple data (SQLite doesn't support Ref encoding via JSON)
      card_data = %{
        id: "card1",
        front: "Persistent",
        back: "Data",
        metadata: %{notes: "persistent notes", created_at: nil}
      }

      _pstate1 = put_in(pstate1["base_card:card1"], card_data)

      # Second session: Reopen and verify data persisted
      pstate2 = create_pstate_with_schema(SQLite, path: db_path, table: "pstate_test")
      writer_pid2 = start_migration_writer(pstate2)

      pstate2 = %{pstate2 | cache: %{}}
      {:ok, restored, _migrated?} = Internal.fetch_and_auto_migrate(pstate2, "base_card:card1")

      # Verify data persisted (keys might be strings)
      front = Map.get(restored, :front) || Map.get(restored, "front")
      metadata = Map.get(restored, :metadata) || Map.get(restored, "metadata")

      assert front == "Persistent"
      assert is_map(metadata)

      notes =
        if is_map(metadata),
          do: Map.get(metadata, :notes) || Map.get(metadata, "notes"),
          else: nil

      assert notes == "persistent notes"

      GenServer.stop(writer_pid2)
    end
  end

  describe "RMX004_9A_T8: Combined migrations" do
    test "all migration patterns work together in single entity" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate)

      complex_card = %{
        id: "card1",
        front: "Complex",
        back: "Card",
        translations: ["t1", "t2", "t3"],
        metadata: "complex notes"
      }

      pstate = put_in(pstate["base_card:card1"], complex_card)
      pstate = %{pstate | cache: %{}}

      {:ok, migrated, _migrated?} = Internal.fetch_and_auto_migrate(pstate, "base_card:card1")

      assert is_map(migrated.translations)
      assert migrated.translations["t1"] == %Ref{key: "translation:t1"}
      assert migrated.translations["t2"] == %Ref{key: "translation:t2"}
      assert migrated.translations["t3"] == %Ref{key: "translation:t3"}

      assert migrated.metadata == %{notes: "complex notes", created_at: nil}
      assert is_map(migrated.metadata)

      Process.sleep(200)

      {:ok, stored} = pstate.adapter.get(pstate.adapter_state, "base_card:card1")

      assert is_map(stored[:translations])
      assert stored[:metadata][:notes] == "complex notes"

      GenServer.stop(writer_pid)
    end
  end

  describe "RMX004_9A_T9: Preloading with migrations" do
    test "preload works with entities that need migration" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate)

      old_card1 = %{
        id: "card1",
        front: "One",
        translations: ["t1"],
        metadata: "card one"
      }

      old_card2 = %{
        id: "card2",
        front: "Two",
        translations: ["t2"],
        metadata: "card two"
      }

      deck = %{
        id: "deck1",
        name: "Test Deck",
        cards: %{
          "card1" => %Ref{key: "base_card:card1"},
          "card2" => %Ref{key: "base_card:card2"}
        }
      }

      pstate = put_in(pstate["base_card:card1"], old_card1)
      pstate = put_in(pstate["base_card:card2"], old_card2)
      pstate = put_in(pstate["base_deck:deck1"], deck)
      pstate = %{pstate | cache: %{}}

      pstate = PState.preload(pstate, "base_deck:deck1", [:cards])

      # Verify cards are in cache (preloaded)
      assert Map.has_key?(pstate.cache, "base_card:card1")
      assert Map.has_key?(pstate.cache, "base_card:card2")

      # Access via pstate[key] to trigger migration if needed
      {:ok, card1} = PState.fetch(pstate, "base_card:card1")
      {:ok, card2} = PState.fetch(pstate, "base_card:card2")

      # After fetch through PState, migrations should have occurred
      assert is_map(card1.translations)
      assert is_map(card2.translations)

      GenServer.stop(writer_pid)
    end
  end

  describe "RMX004_9A_T10: Performance targets" do
    test "sample performance test with 1000 cards" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate, batch_size: 100, flush_interval: 5000)

      num_cards = 1000

      cards =
        Enum.map(1..num_cards, fn i ->
          {
            "base_card:card#{i}",
            %{
              id: "card#{i}",
              front: "Front #{i}",
              back: "Back #{i}",
              translations: ["t#{i}a", "t#{i}b"],
              metadata: "notes for card #{i}"
            }
          }
        end)

      pstate =
        Enum.reduce(cards, pstate, fn {key, card}, acc ->
          put_in(acc[key], card)
        end)

      pstate = %{pstate | cache: %{}}

      {first_read_us, {:ok, first_card, _}} =
        :timer.tc(fn -> Internal.fetch_and_auto_migrate(pstate, "base_card:card500") end)

      first_read_ms = first_read_us / 1000

      assert is_map(first_card.translations)
      assert first_read_ms < 2, "First read took #{first_read_ms}ms, expected <2ms"

      Process.sleep(300)
      pstate = %{pstate | cache: %{}}

      {second_read_us, {:ok, second_card, _}} =
        :timer.tc(fn -> Internal.fetch_and_auto_migrate(pstate, "base_card:card500") end)

      second_read_ms = second_read_us / 1000

      assert second_card == first_card
      assert second_read_ms < 0.5, "Second read took #{second_read_ms}ms, expected <0.5ms"

      keys = Enum.map(1..100, fn i -> "base_card:card#{i}" end)

      {multi_get_us, {:ok, batch_results}} =
        :timer.tc(fn ->
          if function_exported?(pstate.adapter, :multi_get, 2) do
            pstate.adapter.multi_get(pstate.adapter_state, keys)
          else
            {:ok, %{}}
          end
        end)

      multi_get_ms = multi_get_us / 1000

      if map_size(batch_results) > 0 do
        assert multi_get_ms < 20, "multi_get (100 keys) took #{multi_get_ms}ms, expected <20ms"
      end

      deck = %{
        id: "deck1",
        name: "Large Deck",
        cards: Map.new(1..100, fn i -> {"card#{i}", %Ref{key: "base_card:card#{i}"}} end)
      }

      pstate = put_in(pstate["base_deck:deck1"], deck)
      pstate = %{pstate | cache: %{}}

      {preload_us, _preloaded_pstate} =
        :timer.tc(fn ->
          PState.preload(pstate, "base_deck:deck1", [:cards])
        end)

      preload_ms = preload_us / 1000

      assert preload_ms < 100,
             "Preload (100 refs) took #{preload_ms}ms, expected <100ms"

      GenServer.stop(writer_pid)
    end

    test "background flush performance" do
      pstate = create_pstate_with_schema()
      writer_pid = start_migration_writer(pstate, batch_size: 1000, flush_interval: 60000)

      Enum.each(1..100, fn i ->
        MigrationWriter.queue_write("base_card:card#{i}", %{
          id: "card#{i}",
          front: "Test",
          translations: %{},
          metadata: %{notes: "", created_at: nil}
        })
      end)

      {flush_us, :ok} = :timer.tc(fn -> MigrationWriter.flush() end)
      flush_ms = flush_us / 1000

      assert flush_ms < 50, "Flush (100 entries) took #{flush_ms}ms, expected <50ms"

      GenServer.stop(writer_pid)
    end
  end
end
