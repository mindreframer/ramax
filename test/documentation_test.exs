defmodule DocumentationTest do
  @moduledoc """
  Tests that verify documentation examples work correctly.

  This test module ensures that code examples in:
  - README.md
  - guides/spaces.md
  - Module @moduledocs

  ...all compile and execute correctly.
  """

  use ExUnit.Case, async: false

  alias EventStore.Adapters.ETS, as: ETSEventAdapter
  alias PState.Adapters.ETS, as: ETSPStateAdapter

  describe "README examples" do
    test "Quick Start example works" do
      # Create a ContentStore for a specific tenant/environment
      {:ok, crm} = CRMExample.new_tenant("crm_acme_doc_test_#{:rand.uniform(10000)}")

      # Execute commands (validates state, appends events, updates projections)
      {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@acme.com")

      # Query current state
      {:ok, contact} = CRMExample.get_contact(crm, "c1")
      assert contact.id == "c1"
      assert contact.name == "John Doe"
      assert contact.email == "john@acme.com"

      # Rebuild projections from events
      crm = CRMExample.rebuild(crm)

      # Verify data persists after rebuild
      {:ok, contact_after} = CRMExample.get_contact(crm, "c1")
      assert contact_after.id == "c1"
      assert contact_after.name == "John Doe"
    end

    test "Multi-Tenant CRM example works" do
      # Create CRM for different customers (tenants)
      {:ok, acme_crm} = CRMExample.new_tenant("crm_acme_#{:rand.uniform(10000)}")
      {:ok, widgets_crm} = CRMExample.new_tenant("crm_widgets_#{:rand.uniform(10000)}")

      # Add contact to ACME
      {:ok, acme_crm} =
        CRMExample.add_contact(
          acme_crm,
          "c1",
          "John Doe",
          "john@acme.com"
        )

      # Add contact to Widgets (same ID, different space!)
      {:ok, widgets_crm} =
        CRMExample.add_contact(
          widgets_crm,
          "c1",
          "Jane Smith",
          "jane@widgets.com"
        )

      # Each tenant sees only their own data
      {:ok, john} = CRMExample.get_contact(acme_crm, "c1")
      assert john.name == "John Doe"
      assert john.email == "john@acme.com"

      {:ok, jane} = CRMExample.get_contact(widgets_crm, "c1")
      assert jane.name == "Jane Smith"
      assert jane.email == "jane@widgets.com"

      # Rebuild only ACME (Widgets completely unaffected)
      acme_before_count = CRMExample.get_event_count(acme_crm)
      widgets_before_count = CRMExample.get_event_count(widgets_crm)

      acme_crm = CRMExample.rebuild(acme_crm)

      # Verify isolation
      acme_after_count = CRMExample.get_event_count(acme_crm)
      widgets_after_count = CRMExample.get_event_count(widgets_crm)

      assert acme_before_count == acme_after_count
      assert widgets_before_count == widgets_after_count
    end

    test "CMS Staging/Production example works" do
      # Create separate environments in same database
      {:ok, staging} = CMSExample.new_environment("cms_staging_#{:rand.uniform(10000)}")
      {:ok, production} = CMSExample.new_environment("cms_production_#{:rand.uniform(10000)}")

      # Test in staging first
      {:ok, staging} =
        CMSExample.publish_article(
          staging,
          "a1",
          "New Feature",
          "Testing new feature..."
        )

      # Verify in staging, then publish to production
      {:ok, production} =
        CMSExample.publish_article(
          production,
          "a1",
          "New Feature",
          "Testing new feature..."
        )

      # Each environment is completely isolated
      staging_count = CMSExample.get_event_count(staging)
      production_count = CMSExample.get_event_count(production)

      assert staging_count == 1
      assert production_count == 1

      # Verify articles are isolated
      {:ok, staging_article} = CMSExample.get_article(staging, "a1")
      {:ok, prod_article} = CMSExample.get_article(production, "a1")

      assert staging_article.id == "a1"
      assert prod_article.id == "a1"
    end

    test "Space Management example works" do
      # Initialize EventStore
      {:ok, event_store} = EventStore.new(ETSEventAdapter, table_name: :doc_test_events)

      # Create spaces
      space_name_1 = "test_space_1_#{:rand.uniform(10000)}"
      space_name_2 = "test_space_2_#{:rand.uniform(10000)}"

      {:ok, space1, event_store} = Ramax.Space.get_or_create(event_store, space_name_1)
      {:ok, space2, event_store} = Ramax.Space.get_or_create(event_store, space_name_2)

      # List all spaces
      {:ok, spaces} = Ramax.Space.list_all(event_store)
      assert length(spaces) >= 2

      space_names = Enum.map(spaces, & &1.space_name)
      assert space_name_1 in space_names
      assert space_name_2 in space_names

      # Find space by name
      {:ok, found_space} = Ramax.Space.find_by_name(event_store, space_name_1)
      assert found_space.space_id == space1.space_id

      # Delete a space (removes all events and projections)
      :ok = Ramax.Space.delete(event_store, space2.space_id)

      # Verify deleted
      assert {:error, :not_found} == Ramax.Space.find_by_id(event_store, space2.space_id)
    end
  end

  describe "EventStore documentation examples" do
    test "basic EventStore usage works" do
      # Initialize with ETS adapter (development)
      {:ok, store} = EventStore.new(ETSEventAdapter, table_name: :doc_event_test)

      # Create a space
      {:ok, space, store} = Ramax.Space.get_or_create(store, "test_#{:rand.uniform(10000)}")

      # Append an event to a space
      {:ok, event_id, space_sequence, store} =
        EventStore.append(
          store,
          space.space_id,
          "base_card:123",
          "basecard.created",
          %{front: "Hello", back: "Hola"}
        )

      assert is_integer(event_id)
      assert space_sequence == 1

      # Query events for an entity
      {:ok, events} = EventStore.get_events(store, "base_card:123")
      assert length(events) == 1
      assert hd(events).metadata.event_type == "basecard.created"

      # Stream events for a specific space
      stream = EventStore.stream_space_events(store, space.space_id, from_sequence: 0)
      space_events = Enum.to_list(stream)
      assert length(space_events) == 1
    end
  end

  describe "PState documentation examples" do
    test "basic PState usage works" do
      # Create a new PState instance for a specific space
      pstate =
        PState.new("track:uuid",
          space_id: 1,
          adapter: ETSPStateAdapter,
          adapter_opts: [table_name: :doc_pstate_test]
        )

      assert pstate.root_key == "track:uuid"
      assert pstate.space_id == 1

      # Put and fetch data
      pstate = put_in(pstate["user:u1"], %{name: "Alice", email: "alice@example.com"})

      {:ok, user} = PState.fetch(pstate, "user:u1")
      assert user.name == "Alice"
      assert user.email == "alice@example.com"
    end
  end

  describe "ContentStore documentation examples" do
    test "multi-tenancy usage example works" do
      # Use the CRMExample high-level API
      {:ok, acme_crm} = CRMExample.new_tenant("crm_acme_#{:rand.uniform(10000)}")
      {:ok, widgets_crm} = CRMExample.new_tenant("crm_widgets_#{:rand.uniform(10000)}")

      # Add contact to ACME (isolated)
      {:ok, acme_crm} =
        CRMExample.add_contact(acme_crm, "c1", "John", "john@acme.com")

      # Verify ACME has the contact
      {:ok, contact} = CRMExample.get_contact(acme_crm, "c1")
      assert contact.name == "John"

      # Verify Widgets doesn't have the contact
      assert :error == CRMExample.get_contact(widgets_crm, "c1")

      # Rebuild only ACME's projection (not Widgets!)
      acme_crm = CRMExample.rebuild(acme_crm)

      # Verify contact still exists after rebuild
      {:ok, contact_after} = CRMExample.get_contact(acme_crm, "c1")
      assert contact_after.name == "John"
    end
  end

  describe "Space isolation verification" do
    test "same entity_id in different spaces doesn't conflict" do
      # Use CRMExample for easier testing
      {:ok, crm_a} = CRMExample.new_tenant("isolation_a_#{:rand.uniform(10000)}")
      {:ok, crm_b} = CRMExample.new_tenant("isolation_b_#{:rand.uniform(10000)}")

      # Use same contact_id in both spaces
      {:ok, _crm_a} =
        CRMExample.add_contact(crm_a, "contact-1", "Alice", "alice@a.com")

      {:ok, _crm_b} =
        CRMExample.add_contact(crm_b, "contact-1", "Bob", "bob@b.com")

      # Verify each space has its own data
      {:ok, contact_a} = CRMExample.get_contact(crm_a, "contact-1")
      {:ok, contact_b} = CRMExample.get_contact(crm_b, "contact-1")

      assert contact_a.name == "Alice"
      assert contact_b.name == "Bob"

      # Verify no cross-contamination
      assert contact_a.email == "alice@a.com"
      assert contact_b.email == "bob@b.com"
    end

    test "selective rebuild only affects target space" do
      # Use CRMExample for easier testing
      {:ok, crm_small} = CRMExample.new_tenant("rebuild_small_#{:rand.uniform(10000)}")
      {:ok, crm_large} = CRMExample.new_tenant("rebuild_large_#{:rand.uniform(10000)}")

      # Add events to small space
      {:ok, crm_small} =
        CRMExample.add_contact(crm_small, "c1", "User 1", "u1@small.com")

      # Add many events to large space
      crm_large =
        Enum.reduce(1..10, crm_large, fn i, crm ->
          {:ok, updated_crm} =
            CRMExample.add_contact(crm, "c#{i}", "User #{i}", "u#{i}@large.com")

          updated_crm
        end)

      # Get event counts before rebuild
      small_count_before = CRMExample.get_event_count(crm_small)
      large_count_before = CRMExample.get_event_count(crm_large)

      assert small_count_before == 1
      assert large_count_before == 10

      # Rebuild only small space
      crm_small_rebuilt = CRMExample.rebuild(crm_small)

      # Verify small space still has its data
      {:ok, contact} = CRMExample.get_contact(crm_small_rebuilt, "c1")
      assert contact.name == "User 1"

      # Verify large space is unaffected
      large_count_after = CRMExample.get_event_count(crm_large)
      assert large_count_after == 10

      {:ok, contact_large} = CRMExample.get_contact(crm_large, "c5")
      assert contact_large.name == "User 5"
    end
  end

  describe "guides/spaces.md examples" do
    test "space naming conventions example" do
      # Good examples should work
      {:ok, _store} =
        ContentStore.new(
          space_name: "crm_acme",
          event_adapter: ETSEventAdapter,
          pstate_adapter: ETSPStateAdapter
        )

      {:ok, _store} =
        ContentStore.new(
          space_name: "cms_staging",
          event_adapter: ETSEventAdapter,
          pstate_adapter: ETSPStateAdapter
        )

      {:ok, _store} =
        ContentStore.new(
          space_name: "org_sales",
          event_adapter: ETSEventAdapter,
          pstate_adapter: ETSPStateAdapter
        )
    end

    test "space metadata usage example" do
      {:ok, event_store} = EventStore.new(ETSEventAdapter, table_name: :metadata_test)

      {:ok, space, _event_store} =
        Ramax.Space.get_or_create(
          event_store,
          "crm_acme_metadata_#{:rand.uniform(10000)}",
          metadata: %{
            customer_id: "cust_123",
            plan: "enterprise",
            region: "us-east",
            created_by: "admin@acme.com",
            tags: ["premium", "active"]
          }
        )

      assert space.metadata.customer_id == "cust_123"
      assert space.metadata.plan == "enterprise"
      assert "premium" in space.metadata.tags
    end
  end
end
