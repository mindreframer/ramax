defmodule CRMExampleTest do
  use ExUnit.Case, async: true

  doctest CRMExample

  setup do
    # Create a fresh CRM instance for each test with unique table names
    unique_id = :erlang.unique_integer([:positive])

    {:ok, crm} =
      CRMExample.new_tenant(
        "test_crm_#{unique_id}",
        event_opts: [table_name: :"event_store_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_#{unique_id}"]
      )

    {:ok, crm: crm}
  end

  # RMX007_7_T1: Test CRM multi-tenant isolation
  test "RMX007_7_T1: multi-tenant isolation with different spaces" do
    unique_id = :erlang.unique_integer([:positive])

    # Create two different tenant CRM instances
    {:ok, acme_crm} =
      CRMExample.new_tenant(
        "crm_acme_#{unique_id}",
        event_opts: [table_name: :"event_store_acme_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_acme_#{unique_id}"]
      )

    {:ok, widgets_crm} =
      CRMExample.new_tenant(
        "crm_widgets_#{unique_id}",
        event_opts: [table_name: :"event_store_widgets_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_widgets_#{unique_id}"]
      )

    # Add contact to ACME
    {:ok, acme_crm} = CRMExample.add_contact(acme_crm, "c1", "John Doe", "john@acme.com")

    # Add contact to Widgets
    {:ok, widgets_crm} =
      CRMExample.add_contact(widgets_crm, "c2", "Jane Smith", "jane@widgets.com")

    # Verify ACME sees only its contact
    {:ok, acme_contact} = CRMExample.get_contact(acme_crm, "c1")
    assert acme_contact.name == "John Doe"
    assert acme_contact.email == "john@acme.com"
    assert :error = CRMExample.get_contact(acme_crm, "c2")

    # Verify Widgets sees only its contact
    {:ok, widgets_contact} = CRMExample.get_contact(widgets_crm, "c2")
    assert widgets_contact.name == "Jane Smith"
    assert widgets_contact.email == "jane@widgets.com"
    assert :error = CRMExample.get_contact(widgets_crm, "c1")

    # Verify event counts are independent
    assert CRMExample.get_event_count(acme_crm) == 1
    assert CRMExample.get_event_count(widgets_crm) == 1

    # Verify contact counts are independent
    assert CRMExample.get_contact_count(acme_crm) == 1
    assert CRMExample.get_contact_count(widgets_crm) == 1
  end

  # RMX007_7_T2: Test same contact_id in different tenants
  test "RMX007_7_T2: same contact_id works in different tenant spaces" do
    unique_id = :erlang.unique_integer([:positive])

    # Create two different tenant CRM instances
    {:ok, acme_crm} =
      CRMExample.new_tenant(
        "crm_acme_#{unique_id}",
        event_opts: [table_name: :"event_store_acme_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_acme_#{unique_id}"]
      )

    {:ok, widgets_crm} =
      CRMExample.new_tenant(
        "crm_widgets_#{unique_id}",
        event_opts: [table_name: :"event_store_widgets_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_widgets_#{unique_id}"]
      )

    # Add contact with SAME ID to both tenants (should work due to isolation)
    {:ok, acme_crm} = CRMExample.add_contact(acme_crm, "c1", "John Doe", "john@acme.com")

    {:ok, widgets_crm} =
      CRMExample.add_contact(widgets_crm, "c1", "Jane Smith", "jane@widgets.com")

    # Both tenants can have "c1" contact with different data
    {:ok, acme_contact} = CRMExample.get_contact(acme_crm, "c1")
    assert acme_contact.name == "John Doe"

    {:ok, widgets_contact} = CRMExample.get_contact(widgets_crm, "c1")
    assert widgets_contact.name == "Jane Smith"

    # Completely different data, same ID
    assert acme_contact.email != widgets_contact.email
  end

  # RMX007_7_T3: Test tenant rebuild only rebuilds tenant data
  test "RMX007_7_T3: rebuild only affects specific tenant space" do
    unique_id = :erlang.unique_integer([:positive])

    # Create two different tenant CRM instances
    {:ok, acme_crm} =
      CRMExample.new_tenant(
        "crm_acme_#{unique_id}",
        event_opts: [table_name: :"event_store_acme_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_acme_#{unique_id}"]
      )

    {:ok, widgets_crm} =
      CRMExample.new_tenant(
        "crm_widgets_#{unique_id}",
        event_opts: [table_name: :"event_store_widgets_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_widgets_#{unique_id}"]
      )

    # Add multiple contacts to each tenant
    {:ok, acme_crm} = CRMExample.add_contact(acme_crm, "c1", "John", "john@acme.com")
    {:ok, acme_crm} = CRMExample.add_contact(acme_crm, "c2", "Jane", "jane@acme.com")

    {:ok, widgets_crm} = CRMExample.add_contact(widgets_crm, "c1", "Bob", "bob@widgets.com")

    {:ok, widgets_crm} =
      CRMExample.add_contact(widgets_crm, "c2", "Alice", "alice@widgets.com")

    # Get data before rebuild
    {:ok, acme_before} = CRMExample.get_contact(acme_crm, "c1")
    acme_count_before = CRMExample.get_event_count(acme_crm)

    {:ok, widgets_before} = CRMExample.get_contact(widgets_crm, "c1")
    widgets_count_before = CRMExample.get_event_count(widgets_crm)

    # Rebuild only ACME
    acme_crm = CRMExample.rebuild(acme_crm)

    # Get data after ACME rebuild
    {:ok, acme_after} = CRMExample.get_contact(acme_crm, "c1")
    acme_count_after = CRMExample.get_event_count(acme_crm)

    {:ok, widgets_after} = CRMExample.get_contact(widgets_crm, "c1")
    widgets_count_after = CRMExample.get_event_count(widgets_crm)

    # ACME data should be identical after rebuild
    assert acme_before == acme_after
    assert acme_count_before == acme_count_after

    # Widgets should be completely unaffected
    assert widgets_before == widgets_after
    assert widgets_count_before == widgets_count_after

    # Verify counts
    assert acme_count_after == 2
    assert widgets_count_after == 2
  end

  # RMX007_7_T4: Test CRM commands work per tenant
  test "RMX007_7_T4: add_contact and update_contact work correctly", %{crm: crm} do
    # Add contact
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")

    {:ok, contact} = CRMExample.get_contact(crm, "c1")
    assert contact.id == "c1"
    assert contact.name == "John Doe"
    assert contact.email == "john@example.com"
    assert is_integer(contact.created_at)
    assert contact.updated_at == nil

    # Update contact name
    {:ok, crm} = CRMExample.update_contact(crm, "c1", "John D.", nil)

    {:ok, contact} = CRMExample.get_contact(crm, "c1")
    assert contact.name == "John D."
    assert contact.email == "john@example.com"
    assert is_integer(contact.updated_at)

    # Update contact email
    {:ok, crm} = CRMExample.update_contact(crm, "c1", nil, "jd@example.com")

    {:ok, contact} = CRMExample.get_contact(crm, "c1")
    assert contact.name == "John D."
    assert contact.email == "jd@example.com"

    # Update both
    {:ok, crm} = CRMExample.update_contact(crm, "c1", "John Doe", "john.doe@example.com")

    {:ok, contact} = CRMExample.get_contact(crm, "c1")
    assert contact.name == "John Doe"
    assert contact.email == "john.doe@example.com"
  end

  # RMX007_7_T5: Test contact queries are space-scoped
  test "RMX007_7_T5: list_contacts and get_contact_count are space-scoped", %{crm: crm} do
    # Initially empty
    assert CRMExample.list_contacts(crm) == []
    assert CRMExample.get_contact_count(crm) == 0

    # Add contacts
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John", "john@example.com")
    {:ok, crm} = CRMExample.add_contact(crm, "c2", "Jane", "jane@example.com")
    {:ok, crm} = CRMExample.add_contact(crm, "c3", "Bob", "bob@example.com")

    # List all contacts
    contacts = CRMExample.list_contacts(crm)
    assert length(contacts) == 3

    contact_names = Enum.map(contacts, & &1.name) |> Enum.sort()
    assert contact_names == ["Bob", "Jane", "John"]

    # Count contacts
    assert CRMExample.get_contact_count(crm) == 3
  end

  test "new_tenant creates CRM instance with ContentStore" do
    unique_id = :erlang.unique_integer([:positive])

    {:ok, crm} =
      CRMExample.new_tenant(
        "test_#{unique_id}",
        event_opts: [table_name: :"event_store_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_#{unique_id}"]
      )

    assert %CRMExample{} = crm
    assert %ContentStore{} = crm.store
    assert %EventStore{} = crm.store.event_store
    assert %PState{} = crm.store.pstate
  end

  test "add_contact creates contact in PState", %{crm: crm} do
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")

    {:ok, contact} = CRMExample.get_contact(crm, "c1")

    assert contact.id == "c1"
    assert contact.name == "John Doe"
    assert contact.email == "john@example.com"
    assert is_integer(contact.created_at)
    assert contact.updated_at == nil
  end

  test "add_contact appends event to event store", %{crm: crm} do
    event_count_before = CRMExample.get_event_count(crm)

    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")

    event_count_after = CRMExample.get_event_count(crm)

    assert event_count_after == event_count_before + 1
  end

  test "add_contact fails when contact already exists", %{crm: crm} do
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")

    result = CRMExample.add_contact(crm, "c1", "Jane Smith", "jane@example.com")

    assert {:error, {:contact_already_exists, "c1"}} = result
  end

  test "update_contact updates contact information", %{crm: crm} do
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")

    {:ok, crm} = CRMExample.update_contact(crm, "c1", "John D. Doe", "jd@example.com")

    {:ok, contact} = CRMExample.get_contact(crm, "c1")

    assert contact.name == "John D. Doe"
    assert contact.email == "jd@example.com"
    assert is_integer(contact.updated_at)
  end

  test "update_contact sets updated_at timestamp", %{crm: crm} do
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")

    {:ok, contact_before} = CRMExample.get_contact(crm, "c1")

    # Small delay to ensure timestamp changes
    Process.sleep(10)

    {:ok, crm} = CRMExample.update_contact(crm, "c1", "John D.", nil)

    {:ok, contact_after} = CRMExample.get_contact(crm, "c1")

    assert contact_after.updated_at >= contact_before.created_at
  end

  test "update_contact fails when contact not found", %{crm: crm} do
    result = CRMExample.update_contact(crm, "nonexistent", "John", "john@example.com")

    assert {:error, {:contact_not_found, "nonexistent"}} = result
  end

  test "update_contact fails when no changes provided", %{crm: crm} do
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")

    result = CRMExample.update_contact(crm, "c1", nil, nil)

    assert {:error, :no_changes} = result
  end

  test "get_contact returns contact data", %{crm: crm} do
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")

    {:ok, contact} = CRMExample.get_contact(crm, "c1")

    assert contact.id == "c1"
    assert contact.name == "John Doe"
    assert contact.email == "john@example.com"
  end

  test "get_contact returns error when contact not found", %{crm: crm} do
    result = CRMExample.get_contact(crm, "nonexistent")

    assert :error = result
  end

  test "list_contacts returns all contacts", %{crm: crm} do
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John", "john@example.com")
    {:ok, crm} = CRMExample.add_contact(crm, "c2", "Jane", "jane@example.com")
    {:ok, crm} = CRMExample.add_contact(crm, "c3", "Bob", "bob@example.com")

    contacts = CRMExample.list_contacts(crm)

    assert length(contacts) == 3

    contact_ids = Enum.map(contacts, & &1.id) |> Enum.sort()
    assert contact_ids == ["c1", "c2", "c3"]
  end

  test "list_contacts returns empty list when no contacts", %{crm: crm} do
    contacts = CRMExample.list_contacts(crm)

    assert contacts == []
  end

  test "get_contact_count returns correct count", %{crm: crm} do
    assert CRMExample.get_contact_count(crm) == 0

    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John", "john@example.com")
    assert CRMExample.get_contact_count(crm) == 1

    {:ok, crm} = CRMExample.add_contact(crm, "c2", "Jane", "jane@example.com")
    assert CRMExample.get_contact_count(crm) == 2

    {:ok, crm} = CRMExample.add_contact(crm, "c3", "Bob", "bob@example.com")
    assert CRMExample.get_contact_count(crm) == 3
  end

  test "rebuild reconstructs state from events", %{crm: crm} do
    # Add contacts and update one
    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John", "john@example.com")
    {:ok, crm} = CRMExample.add_contact(crm, "c2", "Jane", "jane@example.com")
    {:ok, crm} = CRMExample.update_contact(crm, "c1", "John Doe", nil)

    # Get state before rebuild
    {:ok, contact_before} = CRMExample.get_contact(crm, "c1")
    count_before = CRMExample.get_contact_count(crm)

    # Rebuild
    crm = CRMExample.rebuild(crm)

    # Get state after rebuild
    {:ok, contact_after} = CRMExample.get_contact(crm, "c1")
    count_after = CRMExample.get_contact_count(crm)

    # State should be identical
    assert contact_before == contact_after
    assert count_before == count_after
    assert count_after == 2
  end

  test "get_event_count returns correct event count", %{crm: crm} do
    assert CRMExample.get_event_count(crm) == 0

    {:ok, crm} = CRMExample.add_contact(crm, "c1", "John", "john@example.com")
    assert CRMExample.get_event_count(crm) == 1

    {:ok, crm} = CRMExample.update_contact(crm, "c1", "John Doe", nil)
    assert CRMExample.get_event_count(crm) == 2

    {:ok, crm} = CRMExample.add_contact(crm, "c2", "Jane", "jane@example.com")
    assert CRMExample.get_event_count(crm) == 3
  end
end
