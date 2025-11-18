defmodule CRMExample do
  @moduledoc """
  Multi-tenant CRM example demonstrating space isolation with ContentStore.

  This example shows how to use Ramax spaces to build a multi-tenant CRM system
  where each customer (tenant) has completely isolated data in a shared database.

  ## Features

  - **Tenant Isolation**: Each tenant operates in its own space
  - **Shared Infrastructure**: All tenants use the same database
  - **Independent Sequences**: Each tenant has its own event sequence
  - **Selective Rebuild**: Rebuild one tenant without affecting others
  - **Contact Management**: Add and update contacts per tenant

  ## Architecture

  ```
  ┌─────────────────┐  ┌─────────────────┐
  │ crm_acme        │  │ crm_widgets     │
  │ space_id: 1     │  │ space_id: 2     │
  │ - Contact: John │  │ - Contact: Jane │
  └─────────────────┘  └─────────────────┘
          │                    │
          └────────┬───────────┘
                   ▼
          ┌────────────────┐
          │ Shared Storage │
          │  - events.db   │
          │  - pstate.db   │
          └────────────────┘
  ```

  ## Usage

      # Create CRM stores for two different tenants
      {:ok, acme_crm} = CRMExample.new_tenant("crm_acme")
      {:ok, widgets_crm} = CRMExample.new_tenant("crm_widgets")

      # Add contact to ACME
      {:ok, acme_crm} = CRMExample.add_contact(acme_crm, "c1",
        "John Doe", "john@acme.com")

      # Add contact to Widgets (same contact_id, different space!)
      {:ok, widgets_crm} = CRMExample.add_contact(widgets_crm, "c1",
        "Jane Smith", "jane@widgets.com")

      # Each tenant sees only their own data
      {:ok, john} = CRMExample.get_contact(acme_crm, "c1")
      {:ok, jane} = CRMExample.get_contact(widgets_crm, "c1")

      # Rebuild only ACME (Widgets unaffected)
      acme_crm = CRMExample.rebuild(acme_crm)

  ## References

  - ADR005: Space Support Architecture Decision
  - RMX007: Space Support for Multi-Tenancy Epic
  """

  alias CRMExample.{Commands, EventApplicator, Contact}

  defstruct [:store]

  @type t :: %__MODULE__{
          store: ContentStore.t()
        }

  @doc """
  Create a new CRM instance for a specific tenant.

  ## Parameters

  - `space_name` - Unique space name for the tenant (e.g., "crm_acme")

  ## Options

  - `:event_adapter` - EventStore adapter (default: `EventStore.Adapters.ETS`)
  - `:event_opts` - EventStore options (default: `[]`)
  - `:pstate_adapter` - PState adapter (default: `PState.Adapters.ETS`)
  - `:pstate_opts` - PState options (default: `[]`)

  ## Examples

      # In-memory tenant (development/testing)
      {:ok, crm} = CRMExample.new_tenant("crm_acme")

      # Persistent tenant with SQLite
      {:ok, crm} = CRMExample.new_tenant(
        "crm_acme",
        event_adapter: EventStore.Adapters.SQLite,
        event_opts: [database: "crm.db"],
        pstate_adapter: PState.Adapters.SQLite,
        pstate_opts: [path: "crm.db"]
      )

  """
  @spec new_tenant(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new_tenant(space_name, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:space_name, space_name)
      |> Keyword.put_new(:event_applicator, EventApplicator)
      |> Keyword.put_new(:entity_id_extractor, &extract_entity_id/1)

    case ContentStore.new(opts) do
      {:ok, store} -> {:ok, %__MODULE__{store: store}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Public API - Write Operations

  @doc """
  Add a new contact to the CRM.

  ## Parameters

  - `crm` - Current CRM instance
  - `contact_id` - Unique identifier for the contact
  - `name` - Contact's full name
  - `email` - Contact's email address

  ## Returns

  - `{:ok, updated_crm}` - Contact added successfully
  - `{:error, {:contact_already_exists, contact_id}}` - Contact already exists

  ## Examples

      {:ok, crm} = CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")
      {:ok, crm} = CRMExample.add_contact(crm, "c2", "Jane Smith", "jane@example.com")

      # Error: contact already exists
      {:error, {:contact_already_exists, "c1"}} =
        CRMExample.add_contact(crm, "c1", "John Doe", "john@example.com")

  """
  @spec add_contact(t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, term()}
  def add_contact(crm, contact_id, name, email) do
    params = %{
      contact_id: contact_id,
      name: name,
      email: email
    }

    case ContentStore.execute(crm.store, &Commands.add_contact/2, params) do
      {:ok, _event_ids, updated_store} ->
        {:ok, %{crm | store: updated_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Update an existing contact's information.

  ## Parameters

  - `crm` - Current CRM instance
  - `contact_id` - ID of the contact to update
  - `name` - New name (optional, pass `nil` to keep current)
  - `email` - New email (optional, pass `nil` to keep current)

  ## Returns

  - `{:ok, updated_crm}` - Contact updated successfully
  - `{:error, {:contact_not_found, contact_id}}` - Contact doesn't exist
  - `{:error, :no_changes}` - No changes provided

  ## Examples

      {:ok, crm} = CRMExample.update_contact(crm, "c1", "John D.", nil)
      {:ok, crm} = CRMExample.update_contact(crm, "c1", nil, "john.doe@example.com")
      {:ok, crm} = CRMExample.update_contact(crm, "c1", "John Doe", "jd@example.com")

  """
  @spec update_contact(t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def update_contact(crm, contact_id, name, email) do
    params = %{
      contact_id: contact_id,
      name: name,
      email: email
    }

    case ContentStore.execute(crm.store, &Commands.update_contact/2, params) do
      {:ok, _event_ids, updated_store} ->
        {:ok, %{crm | store: updated_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Public API - Query Operations

  @doc """
  Get a contact by ID.

  ## Parameters

  - `crm` - Current CRM instance
  - `contact_id` - ID of the contact to retrieve

  ## Returns

  - `{:ok, contact}` - Contact data map
  - `:error` - Contact not found

  ## Examples

      {:ok, contact} = CRMExample.get_contact(crm, "c1")
      # => {:ok, %{id: "c1", name: "John Doe", email: "john@example.com", ...}}

      :error = CRMExample.get_contact(crm, "nonexistent")

  """
  @spec get_contact(t(), String.t()) :: {:ok, Contact.t()} | :error
  def get_contact(crm, contact_id) do
    PState.fetch(crm.store.pstate, "contact:#{contact_id}")
  end

  @doc """
  List all contacts in the CRM.

  ## Parameters

  - `crm` - Current CRM instance

  ## Returns

  - List of all contact data maps

  ## Examples

      contacts = CRMExample.list_contacts(crm)
      # => [%{id: "c1", ...}, %{id: "c2", ...}]

  """
  @spec list_contacts(t()) :: [Contact.t()]
  def list_contacts(crm) do
    case PState.fetch(crm.store.pstate, "contacts:all") do
      {:ok, contacts_map} ->
        contacts_map
        |> Map.values()
        |> Enum.sort_by(& &1.created_at)

      :error ->
        []
    end
  end

  @doc """
  Get the total number of contacts in the CRM.

  ## Parameters

  - `crm` - Current CRM instance

  ## Returns

  - Non-negative integer representing the number of contacts

  ## Examples

      count = CRMExample.get_contact_count(crm)
      # => 5

  """
  @spec get_contact_count(t()) :: non_neg_integer()
  def get_contact_count(crm) do
    length(list_contacts(crm))
  end

  @doc """
  Get the total number of events for this tenant.

  ## Parameters

  - `crm` - Current CRM instance

  ## Returns

  - Non-negative integer representing the number of events in this space

  ## Examples

      count = CRMExample.get_event_count(crm)
      # => 10

  """
  @spec get_event_count(t()) :: non_neg_integer()
  def get_event_count(crm) do
    {:ok, seq} =
      EventStore.get_space_latest_sequence(crm.store.event_store, crm.store.space.space_id)

    seq
  end

  @doc """
  Rebuild PState for this tenant from all events in its space.

  Only events belonging to this tenant's space are replayed. Other tenants
  sharing the same database are completely unaffected.

  ## Parameters

  - `crm` - Current CRM instance

  ## Returns

  - Updated CRM with rebuilt PState

  ## Examples

      # Rebuild and verify data integrity
      {:ok, contact_before} = CRMExample.get_contact(crm, "c1")
      crm = CRMExample.rebuild(crm)
      {:ok, contact_after} = CRMExample.get_contact(crm, "c1")
      assert contact_before == contact_after

  """
  @spec rebuild(t()) :: t()
  def rebuild(crm) do
    updated_store = ContentStore.rebuild_pstate(crm.store)
    %{crm | store: updated_store}
  end

  # Helper Functions

  defp extract_entity_id(event_payload) do
    cond do
      Map.has_key?(event_payload, :contact_id) -> event_payload.contact_id
      true -> nil
    end
  end
end

defmodule CRMExample.Contact do
  @moduledoc """
  Contact schema for CRM example.
  """

  @type t :: %{
          id: String.t(),
          name: String.t(),
          email: String.t(),
          created_at: integer(),
          updated_at: integer() | nil
        }
end

defmodule CRMExample.Commands do
  @moduledoc """
  CRM-specific commands that validate state and generate events.
  """

  @type params :: map()
  @type event_spec :: {event_type :: String.t(), payload :: map()}

  @doc """
  Add a new contact.

  ## Parameters
  - `pstate`: Current PState
  - `params`: Map with `:contact_id`, `:name`, `:email`

  ## Returns
  - `{:ok, [event_spec]}` - Contact added event
  - `{:error, {:contact_already_exists, contact_id}}` - Contact exists
  """
  @spec add_contact(PState.t(), params()) :: {:ok, [event_spec()]} | {:error, term()}
  def add_contact(pstate, params) do
    case validate_contact_not_exists(pstate, params.contact_id) do
      :ok ->
        event = %{
          contact_id: params.contact_id,
          name: params.name,
          email: params.email
        }

        {:ok, [{"contact.added", event}]}

      error ->
        error
    end
  end

  @doc """
  Update an existing contact.

  ## Parameters
  - `pstate`: Current PState
  - `params`: Map with `:contact_id`, `:name`, `:email`

  ## Returns
  - `{:ok, [event_spec]}` - Contact updated event
  - `{:error, {:contact_not_found, contact_id}}` - Contact doesn't exist
  - `{:error, :no_changes}` - No changes provided
  """
  @spec update_contact(PState.t(), params()) :: {:ok, [event_spec()]} | {:error, term()}
  def update_contact(pstate, params) do
    with {:ok, contact} <- get_contact(pstate, params.contact_id),
         :ok <- validate_has_changes(params) do
      event = build_update_event(contact, params)
      {:ok, [{"contact.updated", event}]}
    end
  end

  # Validation Helpers

  defp validate_contact_not_exists(pstate, contact_id) do
    case PState.fetch(pstate, "contact:#{contact_id}") do
      {:ok, _} -> {:error, {:contact_already_exists, contact_id}}
      :error -> :ok
    end
  end

  defp get_contact(pstate, contact_id) do
    case PState.fetch(pstate, "contact:#{contact_id}") do
      {:ok, contact} -> {:ok, contact}
      :error -> {:error, {:contact_not_found, contact_id}}
    end
  end

  defp validate_has_changes(params) do
    if params.name == nil && params.email == nil do
      {:error, :no_changes}
    else
      :ok
    end
  end

  defp build_update_event(contact, params) do
    %{
      contact_id: contact.id,
      name: params.name || contact.name,
      email: params.email || contact.email
    }
  end
end

defmodule CRMExample.EventApplicator do
  @moduledoc """
  CRM-specific event applicator - applies CRM events to PState.
  """

  @doc """
  Apply a single event to PState.
  """
  @spec apply_event(PState.t(), EventStore.event()) :: PState.t()
  def apply_event(pstate, event) do
    case event.metadata.event_type do
      "contact.added" -> apply_contact_added(pstate, event)
      "contact.updated" -> apply_contact_updated(pstate, event)
      # Unknown events ignored for forward compatibility
      _ -> pstate
    end
  end

  @doc """
  Apply multiple events to PState in order.
  """
  @spec apply_events(PState.t(), [EventStore.event()]) :: PState.t()
  def apply_events(pstate, events) do
    Enum.reduce(events, pstate, &apply_event(&2, &1))
  end

  # Event Applicators

  defp apply_contact_added(pstate, event) do
    p = event.payload
    contact_key = "contact:#{p.contact_id}"
    created_at = DateTime.to_unix(event.metadata.timestamp)

    contact_data = %{
      id: p.contact_id,
      name: p.name,
      email: p.email,
      created_at: created_at,
      updated_at: nil
    }

    # Add to individual contact key
    pstate = put_in(pstate[contact_key], contact_data)

    # Add to contacts list
    update_in(pstate["contacts:all"], fn
      nil -> %{p.contact_id => contact_data}
      contacts -> Map.put(contacts, p.contact_id, contact_data)
    end)
  end

  defp apply_contact_updated(pstate, event) do
    p = event.payload
    contact_key = "contact:#{p.contact_id}"
    updated_at = DateTime.to_unix(event.metadata.timestamp)

    # Update individual contact
    pstate =
      update_in(pstate[contact_key], fn contact ->
        contact
        |> Map.put(:name, p.name)
        |> Map.put(:email, p.email)
        |> Map.put(:updated_at, updated_at)
      end)

    # Update in contacts list
    update_in(pstate["contacts:all"], fn contacts ->
      contact = pstate[contact_key]
      Map.put(contacts, p.contact_id, contact)
    end)
  end
end
