defmodule PState.AccessProtocolIntegrationTest do
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

    entity :base_deck do
      field(:id, :string)
      field(:name, :string)
    end

    entity :host_card do
      field(:id, :string)
      field(:base_card, :ref)
    end
  end

  # Helper to create PState with ETS adapter
  defp create_pstate(opts) do
    schema = Keyword.get(opts, :schema, nil)
    table_name = :"test_table_#{:erlang.unique_integer([:positive])}"

    pstate =
      PState.new("root:test",
        adapter: PState.Adapters.ETS,
          space_id: 1,
        adapter_opts: [table_name: table_name],
        schema: schema
      )

    # Store initial data if provided
    data = Keyword.get(opts, :data, %{})

    Enum.reduce(data, pstate, fn {key, value}, acc ->
      Internal.put_and_invalidate(acc, key, value)
    end)
  end

  describe "RMX003_5A_T1: Access protocol with auto-migration" do
    test "pstate[key] uses fetch_and_auto_migrate internally" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              back: "world",
              metadata: "old string format",
              deck: "deck123"
            }
          }
        )

      # Access via pstate[key] should trigger auto-migration
      result = pstate["base_card:123"]

      assert result.id == "123"
      assert result.front == "hello"
      assert result.back == "world"
      # Metadata should be migrated from string to map
      assert result.metadata == %{notes: "old string format"}
      # Deck should be migrated from string to ref
      assert result.deck == PState.Ref.new(:base_deck, "deck123")
    end

    test "pstate[key] returns nil for missing key" do
      pstate = create_pstate(schema: TestSchema)

      result = pstate["base_card:missing"]

      assert result == nil
    end

    test "pstate[key] works without schema" do
      pstate =
        create_pstate(
          schema: nil,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old string format"
            }
          }
        )

      result = pstate["base_card:123"]

      # No migration - data stays in old format
      assert result.metadata == "old string format"
    end
  end

  describe "RMX003_5A_T2: pstate[key] with old format" do
    test "migrates old format data on access" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              metadata: "old notes",
              deck: "deck1"
            }
          }
        )

      result = pstate["base_card:123"]

      assert result.metadata == %{notes: "old notes"}
      assert result.deck == PState.Ref.new(:base_deck, "deck1")
    end

    test "migrates only fields that need migration" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "correct",
              back: "format",
              metadata: "needs migration",
              deck: PState.Ref.new(:base_deck, "deck1")
            }
          }
        )

      result = pstate["base_card:123"]

      # Only metadata should be migrated
      assert result.front == "correct"
      assert result.back == "format"
      assert result.metadata == %{notes: "needs migration"}
      assert result.deck == PState.Ref.new(:base_deck, "deck1")
    end

    test "handles missing fields gracefully" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello"
              # metadata and deck missing
            }
          }
        )

      result = pstate["base_card:123"]

      assert result.id == "123"
      assert result.front == "hello"
      assert Map.get(result, :metadata) == nil
      assert Map.get(result, :deck) == nil
    end
  end

  describe "RMX003_5A_T3: pstate[key] with new format" do
    test "returns new format data unchanged" do
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

      result = pstate["base_card:123"]

      assert result == %{
               id: "123",
               front: "hello",
               back: "world",
               metadata: %{notes: "already migrated"},
               deck: PState.Ref.new(:base_deck, "deck1")
             }
    end

    test "does not re-migrate correct format" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: %{notes: "correct", extra: "data"},
              deck: PState.Ref.new(:base_deck, "deck1")
            }
          }
        )

      result = pstate["base_card:123"]

      # Should preserve extra fields in metadata
      assert result.metadata == %{notes: "correct", extra: "data"}
      assert result.deck == PState.Ref.new(:base_deck, "deck1")
    end
  end

  describe "RMX003_5A_T4: ref resolution with migration" do
    test "resolves refs after migration" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              metadata: "old format",
              deck: PState.Ref.new(:base_deck, "deck1")
            },
            "base_deck:deck1" => %{
              id: "deck1",
              name: "My Deck"
            }
          }
        )

      {:ok, result} = PState.get_resolved(pstate, "base_card:123", depth: :infinity)

      # Card data should be migrated
      assert result.metadata == %{notes: "old format"}
      # Ref should resolve to deck data
      assert result.deck.id == "deck1"
      assert result.deck.name == "My Deck"
    end

    test "migrates ref field then resolves it" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              deck: "deck1"
            },
            "base_deck:deck1" => %{
              id: "deck1",
              name: "My Deck"
            }
          }
        )

      {:ok, result} = PState.get_resolved(pstate, "base_card:123", depth: :infinity)

      # Deck should be migrated from string to ref, then resolved
      assert result.deck.id == "deck1"
      assert result.deck.name == "My Deck"
    end

    test "resolves nested refs with migration" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "host_card:456" => %{
              id: "456",
              base_card: PState.Ref.new(:base_card, "123")
            },
            "base_card:123" => %{
              id: "123",
              front: "hello",
              metadata: "old format"
            }
          }
        )

      {:ok, result} = PState.get_resolved(pstate, "host_card:456", depth: :infinity)

      # host_card should resolve base_card ref
      assert result.base_card.id == "123"
      assert result.base_card.front == "hello"
      # base_card's metadata should be migrated during resolution
      assert result.base_card.metadata == %{notes: "old format"}
    end
  end

  describe "RMX003_5A_T5: nested path with migration" do
    test "accesses nested fields with migration" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              metadata: "old format"
            }
          }
        )

      # Access nested path
      result = get_in(pstate, ["base_card:123", :metadata])

      assert result == %{notes: "old format"}
    end

    test "accesses deeply nested refs with migration" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "host_card:456" => %{
              id: "456",
              base_card: PState.Ref.new(:base_card, "123")
            },
            "base_card:123" => %{
              id: "123",
              front: "hello",
              metadata: "nested old format"
            }
          }
        )

      # Access through nested refs - need to resolve first
      {:ok, resolved} = PState.get_resolved(pstate, "host_card:456", depth: :infinity)
      result = resolved.base_card.metadata

      assert result == %{notes: "nested old format"}
    end
  end

  describe "RMX003_5A_T6: Helpers.Value.get with migration" do
    test "Value.get works with migration" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              metadata: "old format"
            }
          }
        )

      result = Helpers.Value.get(pstate, "base_card:123.metadata")

      assert result == %{notes: "old format"}
    end

    test "Value.get with refs and migration" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              front: "hello",
              deck: "deck1"
            },
            "base_deck:deck1" => %{
              id: "deck1",
              name: "My Deck"
            }
          }
        )

      # Access through migrated ref
      result = Helpers.Value.get(pstate, "base_card:123.deck.name")

      assert result == "My Deck"
    end

    test "Value.get with nested refs and migration" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "host_card:456" => %{
              id: "456",
              base_card: PState.Ref.new(:base_card, "123")
            },
            "base_card:123" => %{
              id: "123",
              front: "hello",
              metadata: "deeply nested"
            }
          }
        )

      result = Helpers.Value.get(pstate, "host_card:456.base_card.metadata")

      assert result == %{notes: "deeply nested"}
    end

    test "Value.get returns nil for missing paths with migration" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old format"
            }
          }
        )

      result = Helpers.Value.get(pstate, "base_card:123.nonexistent")

      assert result == nil
    end
  end

  describe "RMX003_5A_T7: multiple reads (idempotent)" do
    test "multiple reads return same migrated result" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old format"
            }
          }
        )

      result1 = pstate["base_card:123"]
      result2 = pstate["base_card:123"]
      result3 = pstate["base_card:123"]

      assert result1.metadata == %{notes: "old format"}
      assert result2.metadata == %{notes: "old format"}
      assert result3.metadata == %{notes: "old format"}
      assert result1 == result2
      assert result2 == result3
    end

    test "migration is idempotent across multiple reads" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "test notes",
              deck: "deck1"
            }
          }
        )

      # Read multiple times
      for _ <- 1..5 do
        result = pstate["base_card:123"]
        assert result.metadata == %{notes: "test notes"}
        assert result.deck == PState.Ref.new(:base_deck, "deck1")
      end
    end

    test "different access patterns produce same result" do
      pstate =
        create_pstate(
          schema: TestSchema,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old format"
            }
          }
        )

      # Access via different methods
      result1 = pstate["base_card:123"]
      result2 = get_in(pstate, ["base_card:123"])
      {:ok, result3} = Access.fetch(pstate, "base_card:123")

      assert result1 == result2
      assert result2 == result3
    end
  end

  describe "RMX003_5A_T8: backward compat (no schema)" do
    test "works without schema - no migration" do
      pstate =
        create_pstate(
          schema: nil,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old format",
              deck: "deck1"
            }
          }
        )

      result = pstate["base_card:123"]

      # No migration should occur
      assert result.metadata == "old format"
      assert result.deck == "deck1"
    end

    test "refs still resolve without schema" do
      pstate =
        create_pstate(
          schema: nil,
          data: %{
            "base_card:123" => %{
              id: "123",
              deck: PState.Ref.new(:base_deck, "deck1")
            },
            "base_deck:deck1" => %{
              id: "deck1",
              name: "My Deck"
            }
          }
        )

      {:ok, result} = PState.get_resolved(pstate, "base_card:123", depth: :infinity)

      # Ref should still resolve even without schema
      assert result.deck.id == "deck1"
      assert result.deck.name == "My Deck"
    end

    test "Value.get works without schema" do
      pstate =
        create_pstate(
          schema: nil,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old format"
            }
          }
        )

      result = Helpers.Value.get(pstate, "base_card:123.metadata")

      # No migration
      assert result == "old format"
    end

    test "get_in works without schema" do
      pstate =
        create_pstate(
          schema: nil,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old format"
            }
          }
        )

      result = get_in(pstate, ["base_card:123", :metadata])

      assert result == "old format"
    end

    test "Access.fetch works without schema" do
      pstate =
        create_pstate(
          schema: nil,
          data: %{
            "base_card:123" => %{
              id: "123",
              metadata: "old format"
            }
          }
        )

      {:ok, result} = Access.fetch(pstate, "base_card:123")

      assert result.metadata == "old format"
    end
  end
end
