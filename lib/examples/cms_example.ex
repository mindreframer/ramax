defmodule CMSExample do
  @moduledoc """
  CMS staging/production example demonstrating space isolation with ContentStore.

  This example shows how to use Ramax spaces to build a CMS system with separate
  staging and production environments in a shared database.

  ## Features

  - **Environment Isolation**: Staging and production operate in separate spaces
  - **Shared Infrastructure**: Both environments use the same database
  - **Independent Sequences**: Each environment has its own event sequence
  - **Safe Testing**: Test in staging without affecting production
  - **Article Management**: Publish and unpublish articles per environment

  ## Architecture

  ```
  ┌─────────────────┐  ┌─────────────────┐
  │ cms_staging     │  │ cms_production  │
  │ space_id: 1     │  │ space_id: 2     │
  │ - Article: Test │  │ - Article: Live │
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

      # Create CMS environments
      {:ok, staging} = CMSExample.new_environment("cms_staging")
      {:ok, production} = CMSExample.new_environment("cms_production")

      # Publish to staging for testing
      {:ok, staging} = CMSExample.publish_article(staging, "a1",
        "New Feature", "Testing new feature...")

      # Test in staging, then publish to production
      {:ok, production} = CMSExample.publish_article(production, "a1",
        "New Feature", "Testing new feature...")

      # Each environment sees only its own articles
      {:ok, staging_article} = CMSExample.get_article(staging, "a1")
      {:ok, prod_article} = CMSExample.get_article(production, "a1")

      # Rebuild only staging (production unaffected)
      staging = CMSExample.rebuild(staging)

  ## References

  - ADR005: Space Support Architecture Decision
  - RMX007: Space Support for Multi-Tenancy Epic
  """

  alias CMSExample.{Commands, EventApplicator, Article}

  defstruct [:store]

  @type t :: %__MODULE__{
          store: ContentStore.t()
        }

  @doc """
  Create a new CMS instance for a specific environment.

  ## Parameters

  - `space_name` - Unique space name for the environment (e.g., "cms_staging", "cms_production")

  ## Options

  - `:event_adapter` - EventStore adapter (default: `EventStore.Adapters.ETS`)
  - `:event_opts` - EventStore options (default: `[]`)
  - `:pstate_adapter` - PState adapter (default: `PState.Adapters.ETS`)
  - `:pstate_opts` - PState options (default: `[]`)

  ## Examples

      # In-memory environment (development/testing)
      {:ok, cms} = CMSExample.new_environment("cms_staging")

      # Persistent environment with SQLite
      {:ok, cms} = CMSExample.new_environment(
        "cms_production",
        event_adapter: EventStore.Adapters.SQLite,
        event_opts: [database: "cms.db"],
        pstate_adapter: PState.Adapters.SQLite,
        pstate_opts: [path: "cms.db"]
      )

  """
  @spec new_environment(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new_environment(space_name, opts \\ []) do
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
  Publish a new article in the CMS.

  ## Parameters

  - `cms` - Current CMS instance
  - `article_id` - Unique identifier for the article
  - `title` - Article title
  - `content` - Article content

  ## Returns

  - `{:ok, updated_cms}` - Article published successfully
  - `{:error, {:article_already_published, article_id}}` - Article already exists

  ## Examples

      {:ok, cms} = CMSExample.publish_article(cms, "a1", "Hello World", "First post!")
      {:ok, cms} = CMSExample.publish_article(cms, "a2", "Feature Update", "New features...")

      # Error: article already published
      {:error, {:article_already_published, "a1"}} =
        CMSExample.publish_article(cms, "a1", "Hello World", "First post!")

  """
  @spec publish_article(t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, term()}
  def publish_article(cms, article_id, title, content) do
    params = %{
      article_id: article_id,
      title: title,
      content: content
    }

    case ContentStore.execute(cms.store, &Commands.publish_article/2, params) do
      {:ok, _event_ids, updated_store} ->
        {:ok, %{cms | store: updated_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unpublish an existing article.

  ## Parameters

  - `cms` - Current CMS instance
  - `article_id` - ID of the article to unpublish

  ## Returns

  - `{:ok, updated_cms}` - Article unpublished successfully
  - `{:error, {:article_not_found, article_id}}` - Article doesn't exist
  - `{:error, {:article_already_unpublished, article_id}}` - Article already unpublished

  ## Examples

      {:ok, cms} = CMSExample.unpublish_article(cms, "a1")

  """
  @spec unpublish_article(t(), String.t()) ::
          {:ok, t()} | {:error, term()}
  def unpublish_article(cms, article_id) do
    params = %{
      article_id: article_id
    }

    case ContentStore.execute(cms.store, &Commands.unpublish_article/2, params) do
      {:ok, _event_ids, updated_store} ->
        {:ok, %{cms | store: updated_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Public API - Query Operations

  @doc """
  Get an article by ID.

  ## Parameters

  - `cms` - Current CMS instance
  - `article_id` - ID of the article to retrieve

  ## Returns

  - `{:ok, article}` - Article data map
  - `:error` - Article not found

  ## Examples

      {:ok, article} = CMSExample.get_article(cms, "a1")
      # => {:ok, %{id: "a1", title: "Hello", content: "...", ...}}

      :error = CMSExample.get_article(cms, "nonexistent")

  """
  @spec get_article(t(), String.t()) :: {:ok, Article.t()} | :error
  def get_article(cms, article_id) do
    PState.fetch(cms.store.pstate, "article:#{article_id}")
  end

  @doc """
  List all published articles in the CMS.

  ## Parameters

  - `cms` - Current CMS instance

  ## Returns

  - List of all published article data maps

  ## Examples

      articles = CMSExample.list_published_articles(cms)
      # => [%{id: "a1", ...}, %{id: "a2", ...}]

  """
  @spec list_published_articles(t()) :: [Article.t()]
  def list_published_articles(cms) do
    case PState.fetch(cms.store.pstate, "articles:published") do
      {:ok, articles_map} ->
        articles_map
        |> Map.values()
        |> Enum.sort_by(& &1.published_at, :desc)

      :error ->
        []
    end
  end

  @doc """
  Get the total number of published articles in the CMS.

  ## Parameters

  - `cms` - Current CMS instance

  ## Returns

  - Non-negative integer representing the number of published articles

  ## Examples

      count = CMSExample.get_published_count(cms)
      # => 5

  """
  @spec get_published_count(t()) :: non_neg_integer()
  def get_published_count(cms) do
    length(list_published_articles(cms))
  end

  @doc """
  Get the total number of events for this environment.

  ## Parameters

  - `cms` - Current CMS instance

  ## Returns

  - Non-negative integer representing the number of events in this space

  ## Examples

      count = CMSExample.get_event_count(cms)
      # => 10

  """
  @spec get_event_count(t()) :: non_neg_integer()
  def get_event_count(cms) do
    {:ok, seq} =
      EventStore.get_space_latest_sequence(cms.store.event_store, cms.store.space.space_id)

    seq
  end

  @doc """
  Rebuild PState for this environment from all events in its space.

  Only events belonging to this environment's space are replayed. Other environments
  sharing the same database are completely unaffected.

  ## Parameters

  - `cms` - Current CMS instance

  ## Returns

  - Updated CMS with rebuilt PState

  ## Examples

      # Rebuild and verify data integrity
      {:ok, article_before} = CMSExample.get_article(cms, "a1")
      cms = CMSExample.rebuild(cms)
      {:ok, article_after} = CMSExample.get_article(cms, "a1")
      assert article_before == article_after

  """
  @spec rebuild(t()) :: t()
  def rebuild(cms) do
    updated_store = ContentStore.rebuild_pstate(cms.store)
    %{cms | store: updated_store}
  end

  # Helper Functions

  defp extract_entity_id(event_payload) do
    cond do
      Map.has_key?(event_payload, :article_id) -> event_payload.article_id
      true -> nil
    end
  end
end

defmodule CMSExample.Article do
  @moduledoc """
  Article schema for CMS example.
  """

  @type t :: %{
          id: String.t(),
          title: String.t(),
          content: String.t(),
          published_at: integer(),
          unpublished_at: integer() | nil,
          status: :published | :unpublished
        }
end

defmodule CMSExample.Commands do
  @moduledoc """
  CMS-specific commands that validate state and generate events.
  """

  @type params :: map()
  @type event_spec :: {event_type :: String.t(), payload :: map()}

  @doc """
  Publish a new article.

  ## Parameters
  - `pstate`: Current PState
  - `params`: Map with `:article_id`, `:title`, `:content`

  ## Returns
  - `{:ok, [event_spec]}` - Article published event
  - `{:error, {:article_already_published, article_id}}` - Article exists
  """
  @spec publish_article(PState.t(), params()) :: {:ok, [event_spec()]} | {:error, term()}
  def publish_article(pstate, params) do
    case validate_article_not_published(pstate, params.article_id) do
      :ok ->
        event = %{
          article_id: params.article_id,
          title: params.title,
          content: params.content
        }

        {:ok, [{"article.published", event}]}

      error ->
        error
    end
  end

  @doc """
  Unpublish an existing article.

  ## Parameters
  - `pstate`: Current PState
  - `params`: Map with `:article_id`

  ## Returns
  - `{:ok, [event_spec]}` - Article unpublished event
  - `{:error, {:article_not_found, article_id}}` - Article doesn't exist
  - `{:error, {:article_already_unpublished, article_id}}` - Article already unpublished
  """
  @spec unpublish_article(PState.t(), params()) :: {:ok, [event_spec()]} | {:error, term()}
  def unpublish_article(pstate, params) do
    with {:ok, article} <- get_article(pstate, params.article_id),
         :ok <- validate_article_published(article) do
      event = %{
        article_id: params.article_id
      }

      {:ok, [{"article.unpublished", event}]}
    end
  end

  # Validation Helpers

  defp validate_article_not_published(pstate, article_id) do
    case PState.fetch(pstate, "article:#{article_id}") do
      {:ok, article} ->
        if article.status == :published do
          {:error, {:article_already_published, article_id}}
        else
          :ok
        end

      :error ->
        :ok
    end
  end

  defp get_article(pstate, article_id) do
    case PState.fetch(pstate, "article:#{article_id}") do
      {:ok, article} -> {:ok, article}
      :error -> {:error, {:article_not_found, article_id}}
    end
  end

  defp validate_article_published(article) do
    if article.status == :unpublished do
      {:error, {:article_already_unpublished, article.id}}
    else
      :ok
    end
  end
end

defmodule CMSExample.EventApplicator do
  @moduledoc """
  CMS-specific event applicator - applies CMS events to PState.
  """

  @doc """
  Apply a single event to PState.
  """
  @spec apply_event(PState.t(), EventStore.event()) :: PState.t()
  def apply_event(pstate, event) do
    case event.metadata.event_type do
      "article.published" -> apply_article_published(pstate, event)
      "article.unpublished" -> apply_article_unpublished(pstate, event)
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

  defp apply_article_published(pstate, event) do
    p = event.payload
    article_key = "article:#{p.article_id}"
    published_at = DateTime.to_unix(event.metadata.timestamp)

    article_data = %{
      id: p.article_id,
      title: p.title,
      content: p.content,
      published_at: published_at,
      unpublished_at: nil,
      status: :published
    }

    # Add to individual article key
    pstate = put_in(pstate[article_key], article_data)

    # Add to published articles list
    update_in(pstate["articles:published"], fn
      nil -> %{p.article_id => article_data}
      articles -> Map.put(articles, p.article_id, article_data)
    end)
  end

  defp apply_article_unpublished(pstate, event) do
    p = event.payload
    article_key = "article:#{p.article_id}"
    unpublished_at = DateTime.to_unix(event.metadata.timestamp)

    # Update individual article
    pstate =
      update_in(pstate[article_key], fn article ->
        article
        |> Map.put(:unpublished_at, unpublished_at)
        |> Map.put(:status, :unpublished)
      end)

    # Remove from published articles list
    update_in(pstate["articles:published"], fn
      nil -> nil
      articles -> Map.delete(articles, p.article_id)
    end)
  end
end
