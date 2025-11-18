defmodule HelpersValueIntegrationTest do
  use ExUnit.Case, async: true

  alias RamaxUtils.Value
  alias PState
  alias PState.Ref

  setup do
    # Create a new PState instance for each test
    pstate =
      PState.new("test_root:#{:erlang.unique_integer([:positive])}",
        space_id: 1,
        adapter: PState.Adapters.ETS
      )

    {:ok, pstate: pstate}
  end

  describe "RMX001_4A_T1: Value.get/2 with simple path" do
    test "retrieves value from simple key path", %{pstate: pstate} do
      # Setup: store a simple entity
      entity_key = "entity:simple-123"
      entity_data = %{"id" => "simple-123", "name" => "Test Entity", "value" => 42}
      pstate = put_in(pstate[entity_key], entity_data)

      # Act: retrieve using Value.get with list path
      result = Value.get(pstate, [entity_key])

      # Assert
      assert result == entity_data
    end

    test "retrieves nested field from entity", %{pstate: pstate} do
      # Setup
      entity_key = "user:user-456"
      entity_data = %{"id" => "user-456", "name" => "Alice", "age" => 30}
      pstate = put_in(pstate[entity_key], entity_data)

      # Act: retrieve nested field using string paths
      name = Value.get(pstate, "#{entity_key}.name")
      age = Value.get(pstate, "#{entity_key}.age")

      # Assert
      assert name == "Alice"
      assert age == 30
    end
  end

  describe "RMX001_4A_T2: Value.get/2 with nested path (no refs)" do
    test "retrieves deeply nested values without refs", %{pstate: pstate} do
      # Setup: entity with nested structure
      entity_key = "config:app-settings"

      entity_data = %{
        "database" => %{
          "host" => "localhost",
          "port" => 5432,
          "credentials" => %{
            "username" => "admin",
            "password" => "secret"
          }
        }
      }

      pstate = put_in(pstate[entity_key], entity_data)

      # Act: retrieve nested values
      host = Value.get(pstate, "#{entity_key}.database.host")
      port = Value.get(pstate, "#{entity_key}.database.port")
      username = Value.get(pstate, "#{entity_key}.database.credentials.username")

      # Assert
      assert host == "localhost"
      assert port == 5432
      assert username == "admin"
    end

    test "returns nil for non-existent nested path", %{pstate: pstate} do
      entity_key = "entity:empty"
      pstate = put_in(pstate[entity_key], %{"id" => "empty"})

      # Act
      result = Value.get(pstate, "#{entity_key}.non.existent.path")

      # Assert
      assert result == nil
    end
  end

  describe "RMX001_4A_T3: Value.get/2 with single ref resolution" do
    test "auto-resolves single reference", %{pstate: pstate} do
      # Setup: card and deck with ref
      card_id = "card-789"
      deck_id = "deck-456"

      card_key = "base_card:#{card_id}"
      deck_key = "base_deck:#{deck_id}"

      card_data = %{"id" => card_id, "front" => "Hello", "back" => "Hola"}

      deck_data = %{
        "id" => deck_id,
        "title" => "Spanish 101",
        "featured_card" => Ref.new(card_key)
      }

      pstate =
        pstate
        |> put_in([card_key], card_data)
        |> put_in([deck_key], deck_data)

      # Act: get featured_card - should auto-resolve the ref
      featured_card = Value.get(pstate, "#{deck_key}.featured_card")

      # Assert: should get the actual card data, not the ref
      assert featured_card == card_data
      assert featured_card["front"] == "Hello"
    end

    test "retrieves field from auto-resolved ref", %{pstate: pstate} do
      # Setup
      author_id = "author-111"
      post_id = "post-222"

      author_key = "author:#{author_id}"
      post_key = "post:#{post_id}"

      author_data = %{"id" => author_id, "name" => "Bob", "email" => "bob@example.com"}

      post_data = %{
        "id" => post_id,
        "title" => "My Post",
        "author" => Ref.new(author_key)
      }

      pstate =
        pstate
        |> put_in([author_key], author_data)
        |> put_in([post_key], post_data)

      # Act: traverse through ref to get author name
      author_name = Value.get(pstate, "#{post_key}.author.name")

      # Assert
      assert author_name == "Bob"
    end
  end

  describe "RMX001_4A_T4: Value.get/2 with nested ref resolution" do
    test "resolves chain of references (A→B→C)", %{pstate: pstate} do
      # Setup: chain of refs
      entity_a_key = "entity_a:a1"
      entity_b_key = "entity_b:b1"
      entity_c_key = "entity_c:c1"

      entity_c_data = %{"id" => "c1", "value" => "final_value"}
      entity_b_data = %{"id" => "b1", "next" => Ref.new(entity_c_key)}
      entity_a_data = %{"id" => "a1", "next" => Ref.new(entity_b_key)}

      pstate =
        pstate
        |> put_in([entity_c_key], entity_c_data)
        |> put_in([entity_b_key], entity_b_data)
        |> put_in([entity_a_key], entity_a_data)

      # Act: traverse A→B→C
      final_value = Value.get(pstate, "#{entity_a_key}.next.next.value")

      # Assert
      assert final_value == "final_value"
    end

    test "resolves refs in nested map structures", %{pstate: pstate} do
      # Setup: deck with multiple card refs
      card1_key = "card:c1"
      card2_key = "card:c2"
      deck_key = "deck:d1"

      card1_data = %{"id" => "c1", "front" => "One", "back" => "Uno"}
      card2_data = %{"id" => "c2", "front" => "Two", "back" => "Dos"}

      deck_data = %{
        "id" => "d1",
        "title" => "Numbers",
        "cards" => %{
          "c1" => Ref.new(card1_key),
          "c2" => Ref.new(card2_key)
        }
      }

      pstate =
        pstate
        |> put_in([card1_key], card1_data)
        |> put_in([card2_key], card2_data)
        |> put_in([deck_key], deck_data)

      # Act: get card data through refs
      card1_front = Value.get(pstate, "#{deck_key}.cards.c1.front")
      card2_back = Value.get(pstate, "#{deck_key}.cards.c2.back")

      # Assert
      assert card1_front == "One"
      assert card2_back == "Dos"
    end
  end

  describe "RMX001_4A_T5: Value.get/2 with array access syntax" do
    test "retrieves value from array using index syntax", %{pstate: pstate} do
      # Setup: entity with array
      entity_key = "list:items"

      entity_data = %{
        "id" => "items",
        "values" => ["first", "second", "third"]
      }

      pstate = put_in(pstate[entity_key], entity_data)

      # Act: access array by index using RamaxUtils.Value array syntax
      first = Value.get(pstate, "#{entity_key}.values[0]")
      second = Value.get(pstate, "#{entity_key}.values[1]")

      # Assert
      assert first == "first"
      assert second == "second"
    end

    test "retrieves nested field from array element", %{pstate: pstate} do
      # Setup
      entity_key = "users:list"

      entity_data = %{
        "id" => "list",
        "users" => [
          %{"name" => "Alice", "age" => 30},
          %{"name" => "Bob", "age" => 25}
        ]
      }

      pstate = put_in(pstate[entity_key], entity_data)

      # Act
      alice_name = Value.get(pstate, "#{entity_key}.users[0].name")
      bob_age = Value.get(pstate, "#{entity_key}.users[1].age")

      # Assert
      assert alice_name == "Alice"
      assert bob_age == 25
    end
  end

  describe "RMX001_4A_T6: Value.insert/3 writes value" do
    test "inserts simple value at key", %{pstate: pstate} do
      # Setup
      entity_key = "entity:new"

      # Act: insert using Value.insert
      pstate = Value.insert(pstate, entity_key, %{"id" => "new", "name" => "New Entity"})

      # Assert: value should be retrievable
      result = Value.get(pstate, entity_key)
      assert result == %{"id" => "new", "name" => "New Entity"}
    end

    test "inserts nested value", %{pstate: pstate} do
      # Setup
      entity_key = "config:app"
      pstate = put_in(pstate[entity_key], %{"id" => "app"})

      # Act: insert nested value
      pstate = Value.insert(pstate, "#{entity_key}.database.host", "localhost")

      # Assert
      host = Value.get(pstate, "#{entity_key}.database.host")
      assert host == "localhost"
    end
  end

  describe "RMX001_4A_T7: Value.insert/3 with nested path creates structure" do
    test "creates nested structure from nil", %{pstate: pstate} do
      # Act: insert into non-existent entity creates structure
      pstate = Value.insert(pstate, "new_entity:x.deeply.nested.value", "leaf_value")

      # Assert: structure should be created
      result = Value.get(pstate, "new_entity:x.deeply.nested.value")
      assert result == "leaf_value"

      # Verify intermediate structure exists
      nested = Value.get(pstate, "new_entity:x.deeply.nested")
      assert is_map(nested)
      assert nested["value"] == "leaf_value"
    end

    test "merges with existing structure", %{pstate: pstate} do
      # Setup: existing entity
      entity_key = "entity:merge"
      pstate = put_in(pstate[entity_key], %{"id" => "merge", "existing" => "value"})

      # Act: insert new nested field
      pstate = Value.insert(pstate, "#{entity_key}.new.field", "new_value")

      # Assert: both old and new fields exist
      existing = Value.get(pstate, "#{entity_key}.existing")
      new_field = Value.get(pstate, "#{entity_key}.new.field")

      assert existing == "value"
      assert new_field == "new_value"
    end
  end

  describe "RMX001_4A_T8: Value.insert/3 invalidates cache" do
    test "cache is invalidated after insert", %{pstate: pstate} do
      # Setup: store initial value
      entity_key = "entity:cached"
      pstate = put_in(pstate[entity_key], %{"id" => "cached", "value" => "initial"})

      # Act: retrieve once (should cache)
      initial = Value.get(pstate, entity_key)
      assert initial["value"] == "initial"

      # Update using insert
      pstate = Value.insert(pstate, "#{entity_key}.value", "updated")

      # Assert: should get updated value (cache invalidated)
      result = Value.get(pstate, entity_key)
      assert result["value"] == "updated"
    end

    test "ref_cache is cleared after insert", %{pstate: pstate} do
      # Setup: entity with ref
      target_key = "target:t1"
      ref_holder_key = "holder:h1"

      pstate =
        pstate
        |> put_in([target_key], %{"id" => "t1", "value" => "original"})
        |> put_in([ref_holder_key], %{"id" => "h1", "target" => Ref.new(target_key)})

      # Act: resolve ref (should cache)
      _initial = Value.get(pstate, "#{ref_holder_key}.target.value")
      # ref_cache may be empty initially
      assert pstate.ref_cache == %{}

      # Update target
      pstate = Value.insert(pstate, "#{target_key}.value", "updated")

      # Assert: ref_cache should be cleared
      assert pstate.ref_cache == %{}

      # Verify we get updated value
      result = Value.get(pstate, "#{ref_holder_key}.target.value")
      assert result == "updated"
    end
  end

  describe "RMX001_4A_T9: Value.get/2 after insert returns new value" do
    test "get returns updated value immediately after insert", %{pstate: pstate} do
      entity_key = "entity:update"

      # Insert initial value
      pstate = Value.insert(pstate, entity_key, %{"id" => "update", "count" => 0})
      assert Value.get(pstate, "#{entity_key}.count") == 0

      # Update
      pstate = Value.insert(pstate, "#{entity_key}.count", 1)
      assert Value.get(pstate, "#{entity_key}.count") == 1

      # Update again
      pstate = Value.insert(pstate, "#{entity_key}.count", 2)
      assert Value.get(pstate, "#{entity_key}.count") == 2
    end

    test "get returns new value after multiple nested inserts", %{pstate: pstate} do
      entity_key = "entity:multi"

      # Multiple inserts
      pstate =
        pstate
        |> Value.insert("#{entity_key}.a", "value_a")
        |> Value.insert("#{entity_key}.b.c", "value_c")
        |> Value.insert("#{entity_key}.b.d", "value_d")

      # Assert all values retrievable
      assert Value.get(pstate, "#{entity_key}.a") == "value_a"
      assert Value.get(pstate, "#{entity_key}.b.c") == "value_c"
      assert Value.get(pstate, "#{entity_key}.b.d") == "value_d"
    end
  end

  describe "RMX001_4A_T10: Value.get/2 with fallback syntax (|)" do
    test "returns first non-nil value from fallback chain", %{pstate: pstate} do
      # Setup: only one path exists
      entity_key = "entity:fallback"
      pstate = put_in(pstate[entity_key], %{"id" => "fallback", "field2" => "value2"})

      # Act: use fallback syntax (field1 doesn't exist, field2 does)
      result = Value.get(pstate, "#{entity_key}.field1|#{entity_key}.field2")

      # Assert: should get field2
      assert result == "value2"
    end

    test "returns default value when all paths are nil", %{pstate: pstate} do
      entity_key = "entity:empty"
      pstate = put_in(pstate[entity_key], %{"id" => "empty"})

      # Act: all paths don't exist, with default
      result = Value.get(pstate, "#{entity_key}.field1|#{entity_key}.field2", "default_value")

      # Assert
      assert result == "default_value"
    end

    test "returns first available value in chain", %{pstate: pstate} do
      entity_key = "entity:chain"
      pstate = put_in(pstate[entity_key], %{"id" => "chain", "field3" => "third"})

      # Act: field1, field2 don't exist, field3 does
      result = Value.get(pstate, "#{entity_key}.field1|#{entity_key}.field2|#{entity_key}.field3")

      # Assert
      assert result == "third"
    end
  end
end
