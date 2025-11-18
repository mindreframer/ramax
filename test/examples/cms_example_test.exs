defmodule CMSExampleTest do
  use ExUnit.Case, async: true

  doctest CMSExample

  setup do
    # Create a fresh CMS instance for each test with unique table names
    unique_id = :erlang.unique_integer([:positive])

    {:ok, cms} =
      CMSExample.new_environment(
        "test_cms_#{unique_id}",
        event_opts: [table_name: :"event_store_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_#{unique_id}"]
      )

    {:ok, cms: cms}
  end

  # RMX007_8_T1: Test CMS staging/production isolation
  test "RMX007_8_T1: staging and production environments are isolated" do
    unique_id = :erlang.unique_integer([:positive])

    # Create staging and production environments
    {:ok, staging} =
      CMSExample.new_environment(
        "cms_staging_#{unique_id}",
        event_opts: [table_name: :"event_store_staging_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_staging_#{unique_id}"]
      )

    {:ok, production} =
      CMSExample.new_environment(
        "cms_production_#{unique_id}",
        event_opts: [table_name: :"event_store_production_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_production_#{unique_id}"]
      )

    # Publish article to staging
    {:ok, staging} =
      CMSExample.publish_article(staging, "a1", "Test Feature", "Testing new feature...")

    # Publish article to production
    {:ok, production} =
      CMSExample.publish_article(
        production,
        "a2",
        "Production Release",
        "Announcing new release..."
      )

    # Verify staging sees only its article
    {:ok, staging_article} = CMSExample.get_article(staging, "a1")
    assert staging_article.title == "Test Feature"
    assert staging_article.content == "Testing new feature..."
    assert :error = CMSExample.get_article(staging, "a2")

    # Verify production sees only its article
    {:ok, prod_article} = CMSExample.get_article(production, "a2")
    assert prod_article.title == "Production Release"
    assert prod_article.content == "Announcing new release..."
    assert :error = CMSExample.get_article(production, "a1")

    # Verify event counts are independent
    assert CMSExample.get_event_count(staging) == 1
    assert CMSExample.get_event_count(production) == 1

    # Verify published counts are independent
    assert CMSExample.get_published_count(staging) == 1
    assert CMSExample.get_published_count(production) == 1
  end

  # RMX007_8_T2: Test staging changes don't affect production
  test "RMX007_8_T2: staging changes don't affect production" do
    unique_id = :erlang.unique_integer([:positive])

    # Create staging and production environments
    {:ok, staging} =
      CMSExample.new_environment(
        "cms_staging_#{unique_id}",
        event_opts: [table_name: :"event_store_staging_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_staging_#{unique_id}"]
      )

    {:ok, production} =
      CMSExample.new_environment(
        "cms_production_#{unique_id}",
        event_opts: [table_name: :"event_store_production_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_production_#{unique_id}"]
      )

    # Publish same article ID to both environments (different content)
    {:ok, staging} =
      CMSExample.publish_article(staging, "a1", "Draft Article", "Work in progress...")

    {:ok, production} =
      CMSExample.publish_article(production, "a1", "Final Article", "Published content...")

    # Verify each environment has different content for same ID
    {:ok, staging_article} = CMSExample.get_article(staging, "a1")
    assert staging_article.title == "Draft Article"
    assert staging_article.content == "Work in progress..."

    {:ok, prod_article} = CMSExample.get_article(production, "a1")
    assert prod_article.title == "Final Article"
    assert prod_article.content == "Published content..."

    # Unpublish in staging
    {:ok, staging} = CMSExample.unpublish_article(staging, "a1")

    # Verify staging article is unpublished
    {:ok, staging_article} = CMSExample.get_article(staging, "a1")
    assert staging_article.status == :unpublished
    assert CMSExample.get_published_count(staging) == 0

    # Verify production article is still published (unaffected)
    {:ok, prod_article} = CMSExample.get_article(production, "a1")
    assert prod_article.status == :published
    assert CMSExample.get_published_count(production) == 1
  end

  # RMX007_8_T3: Test CMS rebuild per environment
  test "RMX007_8_T3: rebuild only affects specific environment" do
    unique_id = :erlang.unique_integer([:positive])

    # Create staging and production environments
    {:ok, staging} =
      CMSExample.new_environment(
        "cms_staging_#{unique_id}",
        event_opts: [table_name: :"event_store_staging_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_staging_#{unique_id}"]
      )

    {:ok, production} =
      CMSExample.new_environment(
        "cms_production_#{unique_id}",
        event_opts: [table_name: :"event_store_production_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_production_#{unique_id}"]
      )

    # Add multiple articles to each environment
    {:ok, staging} =
      CMSExample.publish_article(staging, "a1", "Staging 1", "Content 1...")

    {:ok, staging} =
      CMSExample.publish_article(staging, "a2", "Staging 2", "Content 2...")

    {:ok, production} =
      CMSExample.publish_article(production, "a1", "Production 1", "Live content 1...")

    {:ok, production} =
      CMSExample.publish_article(production, "a2", "Production 2", "Live content 2...")

    # Get data before rebuild
    {:ok, staging_before} = CMSExample.get_article(staging, "a1")
    staging_count_before = CMSExample.get_event_count(staging)

    {:ok, prod_before} = CMSExample.get_article(production, "a1")
    prod_count_before = CMSExample.get_event_count(production)

    # Rebuild only staging
    staging = CMSExample.rebuild(staging)

    # Get data after staging rebuild
    {:ok, staging_after} = CMSExample.get_article(staging, "a1")
    staging_count_after = CMSExample.get_event_count(staging)

    {:ok, prod_after} = CMSExample.get_article(production, "a1")
    prod_count_after = CMSExample.get_event_count(production)

    # Staging data should be identical after rebuild
    assert staging_before == staging_after
    assert staging_count_before == staging_count_after

    # Production should be completely unaffected
    assert prod_before == prod_after
    assert prod_count_before == prod_count_after

    # Verify counts
    assert staging_count_after == 2
    assert prod_count_after == 2
  end

  # RMX007_8_T4: Test article queries are space-scoped
  test "RMX007_8_T4: list_published_articles is space-scoped", %{cms: cms} do
    # Initially empty
    assert CMSExample.list_published_articles(cms) == []
    assert CMSExample.get_published_count(cms) == 0

    # Publish articles
    {:ok, cms} = CMSExample.publish_article(cms, "a1", "First", "First content...")
    {:ok, cms} = CMSExample.publish_article(cms, "a2", "Second", "Second content...")
    {:ok, cms} = CMSExample.publish_article(cms, "a3", "Third", "Third content...")

    # List all published articles
    articles = CMSExample.list_published_articles(cms)
    assert length(articles) == 3

    article_titles = Enum.map(articles, & &1.title) |> Enum.sort()
    assert article_titles == ["First", "Second", "Third"]

    # Count published articles
    assert CMSExample.get_published_count(cms) == 3

    # Unpublish one article
    {:ok, cms} = CMSExample.unpublish_article(cms, "a2")

    # List published articles (should exclude unpublished)
    articles = CMSExample.list_published_articles(cms)
    assert length(articles) == 2

    article_titles = Enum.map(articles, & &1.title) |> Enum.sort()
    assert article_titles == ["First", "Third"]

    # Count published articles
    assert CMSExample.get_published_count(cms) == 2
  end

  test "new_environment creates CMS instance with ContentStore" do
    unique_id = :erlang.unique_integer([:positive])

    {:ok, cms} =
      CMSExample.new_environment(
        "test_#{unique_id}",
        event_opts: [table_name: :"event_store_#{unique_id}"],
        pstate_opts: [table_name: :"pstate_#{unique_id}"]
      )

    assert %CMSExample{} = cms
    assert %ContentStore{} = cms.store
    assert %EventStore{} = cms.store.event_store
    assert %PState{} = cms.store.pstate
  end

  test "publish_article creates article in PState", %{cms: cms} do
    {:ok, cms} =
      CMSExample.publish_article(cms, "a1", "Hello World", "This is my first article")

    {:ok, article} = CMSExample.get_article(cms, "a1")

    assert article.id == "a1"
    assert article.title == "Hello World"
    assert article.content == "This is my first article"
    assert is_integer(article.published_at)
    assert article.unpublished_at == nil
    assert article.status == :published
  end

  test "publish_article appends event to event store", %{cms: cms} do
    event_count_before = CMSExample.get_event_count(cms)

    {:ok, cms} = CMSExample.publish_article(cms, "a1", "Test", "Content...")

    event_count_after = CMSExample.get_event_count(cms)

    assert event_count_after == event_count_before + 1
  end

  test "publish_article fails when article already published", %{cms: cms} do
    {:ok, cms} = CMSExample.publish_article(cms, "a1", "First", "Content...")

    result = CMSExample.publish_article(cms, "a1", "Second", "Different content...")

    assert {:error, {:article_already_published, "a1"}} = result
  end

  test "unpublish_article unpublishes article", %{cms: cms} do
    {:ok, cms} = CMSExample.publish_article(cms, "a1", "Test", "Content...")

    {:ok, cms} = CMSExample.unpublish_article(cms, "a1")

    {:ok, article} = CMSExample.get_article(cms, "a1")

    assert article.status == :unpublished
    assert is_integer(article.unpublished_at)
  end

  test "unpublish_article removes article from published list", %{cms: cms} do
    {:ok, cms} = CMSExample.publish_article(cms, "a1", "Test", "Content...")
    {:ok, cms} = CMSExample.publish_article(cms, "a2", "Test 2", "Content 2...")

    assert CMSExample.get_published_count(cms) == 2

    {:ok, cms} = CMSExample.unpublish_article(cms, "a1")

    assert CMSExample.get_published_count(cms) == 1

    # Only a2 should be in published list
    articles = CMSExample.list_published_articles(cms)
    assert length(articles) == 1
    assert hd(articles).id == "a2"
  end

  test "unpublish_article fails when article not found", %{cms: cms} do
    result = CMSExample.unpublish_article(cms, "nonexistent")

    assert {:error, {:article_not_found, "nonexistent"}} = result
  end

  test "unpublish_article fails when article already unpublished", %{cms: cms} do
    {:ok, cms} = CMSExample.publish_article(cms, "a1", "Test", "Content...")
    {:ok, cms} = CMSExample.unpublish_article(cms, "a1")

    result = CMSExample.unpublish_article(cms, "a1")

    assert {:error, {:article_already_unpublished, "a1"}} = result
  end

  test "get_article returns article data", %{cms: cms} do
    {:ok, cms} = CMSExample.publish_article(cms, "a1", "Test Article", "Content here...")

    {:ok, article} = CMSExample.get_article(cms, "a1")

    assert article.id == "a1"
    assert article.title == "Test Article"
    assert article.content == "Content here..."
  end

  test "get_article returns error when article not found", %{cms: cms} do
    result = CMSExample.get_article(cms, "nonexistent")

    assert :error = result
  end

  test "list_published_articles returns all published articles", %{cms: cms} do
    {:ok, cms} = CMSExample.publish_article(cms, "a1", "First", "Content 1...")
    {:ok, cms} = CMSExample.publish_article(cms, "a2", "Second", "Content 2...")
    {:ok, cms} = CMSExample.publish_article(cms, "a3", "Third", "Content 3...")

    articles = CMSExample.list_published_articles(cms)

    assert length(articles) == 3

    article_ids = Enum.map(articles, & &1.id) |> Enum.sort()
    assert article_ids == ["a1", "a2", "a3"]
  end

  test "list_published_articles returns empty list when no articles", %{cms: cms} do
    articles = CMSExample.list_published_articles(cms)

    assert articles == []
  end

  test "list_published_articles sorted by published_at descending", %{cms: cms} do
    # Publish articles with small delays to ensure different timestamps
    {:ok, cms} = CMSExample.publish_article(cms, "a1", "First", "Content 1...")
    Process.sleep(100)
    {:ok, cms} = CMSExample.publish_article(cms, "a2", "Second", "Content 2...")
    Process.sleep(100)
    {:ok, cms} = CMSExample.publish_article(cms, "a3", "Third", "Content 3...")

    articles = CMSExample.list_published_articles(cms)

    # Most recent first (should be a3, a2, a1 if timestamps differ, otherwise order may vary)
    article_ids = Enum.map(articles, & &1.id)

    # Verify all articles are present
    assert length(article_ids) == 3
    assert "a1" in article_ids
    assert "a2" in article_ids
    assert "a3" in article_ids

    # Verify they're sorted by published_at descending
    assert articles == Enum.sort_by(articles, & &1.published_at, :desc)
  end

  test "get_published_count returns correct count", %{cms: cms} do
    assert CMSExample.get_published_count(cms) == 0

    {:ok, cms} = CMSExample.publish_article(cms, "a1", "First", "Content 1...")
    assert CMSExample.get_published_count(cms) == 1

    {:ok, cms} = CMSExample.publish_article(cms, "a2", "Second", "Content 2...")
    assert CMSExample.get_published_count(cms) == 2

    {:ok, cms} = CMSExample.publish_article(cms, "a3", "Third", "Content 3...")
    assert CMSExample.get_published_count(cms) == 3
  end

  test "rebuild reconstructs state from events", %{cms: cms} do
    # Publish articles and unpublish one
    {:ok, cms} = CMSExample.publish_article(cms, "a1", "First", "Content 1...")
    {:ok, cms} = CMSExample.publish_article(cms, "a2", "Second", "Content 2...")
    {:ok, cms} = CMSExample.unpublish_article(cms, "a1")

    # Get state before rebuild
    {:ok, article_before} = CMSExample.get_article(cms, "a1")
    count_before = CMSExample.get_published_count(cms)

    # Rebuild
    cms = CMSExample.rebuild(cms)

    # Get state after rebuild
    {:ok, article_after} = CMSExample.get_article(cms, "a1")
    count_after = CMSExample.get_published_count(cms)

    # State should be identical
    assert article_before == article_after
    assert count_before == count_after
    assert count_after == 1
    assert article_after.status == :unpublished
  end

  test "get_event_count returns correct event count", %{cms: cms} do
    assert CMSExample.get_event_count(cms) == 0

    {:ok, cms} = CMSExample.publish_article(cms, "a1", "First", "Content...")
    assert CMSExample.get_event_count(cms) == 1

    {:ok, cms} = CMSExample.unpublish_article(cms, "a1")
    assert CMSExample.get_event_count(cms) == 2

    {:ok, cms} = CMSExample.publish_article(cms, "a2", "Second", "Content 2...")
    assert CMSExample.get_event_count(cms) == 3
  end
end
