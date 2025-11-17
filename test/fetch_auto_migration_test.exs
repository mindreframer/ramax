defmodule PState.FetchAutoMigrationTest do
  use ExUnit.Case, async: true

  alias PState.Internal

  # Test schema with migrations
  defmodule TestSchema do
    use PState.Schema

    entity :base_card do
      field(:id, :string)
      field(:front, :string)
      field(:back, :string)

      field :metadata, :map do
        migrate(fn
          str when is_binary(str) -> %{notes: str}
          map when is_map(map) -> map
        end)
      end

      field :deck, :ref do
        migrate(fn
          id when is_binary(id) -> PState.Ref.new(:base_deck, id)
          %PState.Ref{} = ref -> ref
        end)
      end
    end

    entity :host_card do
      field(:id, :string)
      field(:base_card, :ref)
    end
  end

  # Helper to create PState with ETS adapter
  defp create_pstate(opts \\ []) do
    schema = Keyword.get(opts, :schema, nil)
    table_name = :"test_table_#{:erlang.unique_integer([:positive])}"

    pstate =
      PState.new("root:test",
        adapter: PState.Adapters.ETS,
        adapter_opts: [table_name: table_name],
        schema: schema
      )

    # Store initial data if provided
    data = Keyword.get(opts, :data, %{})

    Enum.reduce(data, pstate, fn {key, value}, acc ->
      Internal.put_and_invalidate(acc, key, value)
    end)
  end

  describe "RMX003_4A_T1: fetch_and_auto_migrate without schema" do
    test "uses old fetch_with_cache when schema is nil" do
      pstate =
        create_pstate(
          schema: nil,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              back: "world"
            }
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:123")

      assert {:ok, data} = result
      assert data.id == "123"
      assert data.front == "hello"
      assert data.back == "world"
    end

    test "returns :error for missing key when no schema" do
      pstate = create_pstate(schema: nil)

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:missing")

      assert result == :error
    end

    test "handles old format data without migration when no schema" do
      # Old format with string metadata
      pstate =
        create_pstate(
          schema: nil,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old string format",
              deck: "deck123"
            }
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:123")

      assert {:ok, data} = result
      # No migration - data stays in old format
      assert data.metadata == "old string format"
      assert data.deck == "deck123"
    end
  end

  describe "RMX003_4A_T2: fetch_and_auto_migrate with schema" do
    test "fetches and returns data when schema present" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              back: "world",
              metadata: %{notes: "already migrated"},
              deck: PState.Ref.new(:base_deck, "deck1")
            }
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:123")

      assert {:ok, data} = result
      assert data.id == "123"
      assert data.front == "hello"
      assert data.back == "world"
      assert data.metadata == %{notes: "already migrated"}
      assert data.deck == PState.Ref.new(:base_deck, "deck1")
    end

    test "fetches entity without migrate_fn fields" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "host_card:456" => %{
              id: "456",
              base_card: PState.Ref.new(:base_card, "123")
            }
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "host_card:456")

      assert {:ok, data} = result
      assert data.id == "456"
      assert data.base_card == PState.Ref.new(:base_card, "123")
    end
  end

  describe "RMX003_4A_T3: fetch_and_auto_migrate with old format data" do
    test "migrates string metadata to map" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              back: "world",
              metadata: "old string notes",
              deck: PState.Ref.new(:base_deck, "deck1")
            }
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:123")

      assert {:ok, data} = result
      # metadata should be migrated from string to map
      assert data.metadata == %{notes: "old string notes"}
      assert data.deck == PState.Ref.new(:base_deck, "deck1")
    end

    test "migrates string deck id to ref" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              back: "world",
              metadata: %{notes: "already migrated"},
              deck: "deck123"
            }
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:123")

      assert {:ok, data} = result
      # deck should be migrated from string to ref
      assert data.deck == PState.Ref.new(:base_deck, "deck123")
      assert data.metadata == %{notes: "already migrated"}
    end

    test "migrates multiple fields at once" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              back: "world",
              metadata: "old string notes",
              deck: "deck123"
            }
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:123")

      assert {:ok, data} = result
      # Both fields should be migrated
      assert data.metadata == %{notes: "old string notes"}
      assert data.deck == PState.Ref.new(:base_deck, "deck123")
    end
  end

  describe "RMX003_4A_T4: fetch_and_auto_migrate with new format data" do
    test "returns new format data unchanged" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              back: "world",
              metadata: %{notes: "new format"},
              deck: PState.Ref.new(:base_deck, "deck1")
            }
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:123")

      assert {:ok, data} = result
      assert data.metadata == %{notes: "new format"}
      assert data.deck == PState.Ref.new(:base_deck, "deck1")
    end

    test "does not re-migrate already migrated data" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "test",
              back: "data",
              metadata: %{notes: "already a map"},
              deck: PState.Ref.new(:base_deck, "deck1")
            }
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:123")

      assert {:ok, data} = result
      # Data should remain exactly the same
      assert data == %{
               id: "123",
               front: "test",
               back: "data",
               metadata: %{notes: "already a map"},
               deck: PState.Ref.new(:base_deck, "deck1")
             }
    end
  end

  describe "RMX003_4A_T5: fetch_and_auto_migrate with missing entity" do
    test "returns :error when entity not found" do
      pstate = create_pstate(schema: TestSchema)

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:missing")

      assert result == :error
    end

    test "returns :error when key does not exist in storage" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{id: "123"}
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "base_card:999")

      assert result == :error
    end

    test "returns :error for different entity type not in storage" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{id: "123"}
          }
        )

      result = Internal.fetch_and_auto_migrate(pstate, "host_card:999")

      assert result == :error
    end
  end

  describe "RMX003_4A_T6: fetch_and_auto_migrate migration happens every read" do
    test "migration is applied on every fetch" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              metadata: "old string"
            }
          }
        )

      # First read - should migrate
      result1 = Internal.fetch_and_auto_migrate(pstate, "base_card:123")
      assert {:ok, data1} = result1
      assert data1.metadata == %{notes: "old string"}

      # Second read - should migrate again (synchronous migration on every read)
      result2 = Internal.fetch_and_auto_migrate(pstate, "base_card:123")
      assert {:ok, data2} = result2
      assert data2.metadata == %{notes: "old string"}

      # Third read - should migrate again
      result3 = Internal.fetch_and_auto_migrate(pstate, "base_card:123")
      assert {:ok, data3} = result3
      assert data3.metadata == %{notes: "old string"}
    end

    test "no background write happens - data stays in old format" do
      # Store old format data
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old string",
              deck: "deck123"
            }
          }
        )

      # Fetch and migrate
      {:ok, migrated_data} = Internal.fetch_and_auto_migrate(pstate, "base_card:123")
      assert migrated_data.metadata == %{notes: "old string"}
      assert migrated_data.deck == PState.Ref.new(:base_deck, "deck123")

      # Check raw storage - should still be in old format
      {:ok, raw_data} = Internal.fetch_with_cache(pstate, "base_card:123")
      # Raw data should still be old format (no background write yet)
      assert raw_data.metadata == "old string"
      assert raw_data.deck == "deck123"
    end

    test "migration happens synchronously on each read for different keys" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{id: "123", metadata: "old1"},
            "base_card:456" => %{id: "456", metadata: "old2"}
          }
        )

      # Read first key
      {:ok, data1} = Internal.fetch_and_auto_migrate(pstate, "base_card:123")
      assert data1.metadata == %{notes: "old1"}

      # Read second key
      {:ok, data2} = Internal.fetch_and_auto_migrate(pstate, "base_card:456")
      assert data2.metadata == %{notes: "old2"}

      # Read first key again - migrates again
      {:ok, data1_again} = Internal.fetch_and_auto_migrate(pstate, "base_card:123")
      assert data1_again.metadata == %{notes: "old1"}
    end
  end
end
