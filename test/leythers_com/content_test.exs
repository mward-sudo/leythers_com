defmodule LeythersCom.ContentTest do
  use LeythersCom.DataCase, async: true

  alias Ecto.UUID
  alias LeythersCom.Content
  alias LeythersCom.Content.ArticleSource
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Ingestion

  @valid_attrs %{
    slug: "leigh-leopards-grand-final",
    title: "Leigh Leopards Win Grand Final",
    body: "An incredible victory for the Leopards."
  }

  describe "create_article/1" do
    test "inserts a valid article" do
      assert {:ok, %PermanentArticle{} = article} = Content.create_article(@valid_attrs)
      assert article.slug == "leigh-leopards-grand-final"
      assert article.status == "published"
      assert article.version == 1
    end

    test "returns error changeset for missing required fields" do
      assert {:error, %Ecto.Changeset{}} = Content.create_article(%{})
    end

    test "returns error changeset on duplicate slug" do
      {:ok, _} = Content.create_article(@valid_attrs)
      assert {:error, %Ecto.Changeset{}} = Content.create_article(@valid_attrs)
    end
  end

  describe "get_article!/1" do
    test "returns the article for a given id" do
      {:ok, article} = Content.create_article(@valid_attrs)
      assert Content.get_article!(article.id).id == article.id
    end

    test "raises for unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        Content.get_article!(UUID.generate())
      end
    end
  end

  describe "get_article_by_slug/1" do
    test "returns the article for a given slug" do
      {:ok, article} = Content.create_article(@valid_attrs)
      assert {:ok, found} = Content.get_article_by_slug(article.slug)
      assert found.id == article.id
    end

    test "returns error tuple when slug not found" do
      assert {:error, :not_found} = Content.get_article_by_slug("nonexistent-slug")
    end
  end

  describe "publish_article/2" do
    test "publishes immediately with a generated slug and no source links" do
      assert {:ok, %PermanentArticle{} = article} =
               Content.publish_article(%{
                 title: "Leigh Leopards Fast Track",
                 body: "Published by hand in a single transaction."
               })

      assert article.slug == "leigh-leopards-fast-track"
      assert article.author_type == "human_admin"
      assert article.status == "published"
      assert article.version == 1
      assert count_article_sources(article.id) == 0
    end

    test "attaches selected source links atomically" do
      {:ok, source_a} =
        Ingestion.create_raw_source(%{
          title: "Source A",
          url: "https://example.com/source-a",
          origin_provider: "rss",
          external_published_at: ~U[2026-06-01 10:00:00.000000Z]
        })

      {:ok, source_b} =
        Ingestion.create_raw_source(%{
          title: "Source B",
          url: "https://example.com/source-b",
          origin_provider: "rss",
          external_published_at: ~U[2026-06-01 11:00:00.000000Z]
        })

      assert {:ok, %PermanentArticle{} = article} =
               Content.publish_article(
                 %{
                   title: "Leigh Leopards Linked Story",
                   body: "A manually published story with sources."
                 },
                 [source_a.id, source_b.id]
               )

      assert count_article_sources(article.id) == 2
    end

    test "rolls back when a selected source link fails" do
      {:ok, source} =
        Ingestion.create_raw_source(%{
          title: "Valid Source",
          url: "https://example.com/valid-source",
          origin_provider: "rss",
          external_published_at: ~U[2026-06-01 10:00:00.000000Z]
        })

      assert {:error, _} =
               Content.publish_article(
                 %{
                   title: "Leigh Leopards Broken Publish",
                   body: "This publish should fail and roll back."
                 },
                 [source.id, UUID.generate()]
               )

      assert Repo.aggregate(PermanentArticle, :count, :id) == 0
      assert Repo.aggregate(ArticleSource, :count, :id) == 0
    end

    test "uses a deterministic collision-safe slug" do
      {:ok, _} =
        Content.create_article(%{
          slug: "collision-safe-title",
          title: "Collision Safe Title",
          body: "Existing article."
        })

      assert {:ok, %PermanentArticle{} = article} =
               Content.publish_article(%{
                 title: "Collision Safe Title",
                 body: "New publish should get the next slug."
               })

      assert article.slug == "collision-safe-title-2"
    end

    test "emits telemetry for successful manual publish" do
      attach_telemetry_handler([:leythers_com, :content, :manual_publish, :stop])

      assert {:ok, %PermanentArticle{} = article} =
               Content.publish_article(%{
                 title: "Telemetry Publish",
                 body: "Telemetry body"
               })

      assert_receive {:telemetry_event, [:leythers_com, :content, :manual_publish, :stop],
                      measurements, metadata}

      assert measurements.duration > 0
      assert measurements.count == 1
      assert metadata.result == :ok
      assert metadata.article_id == article.id
      assert metadata.source_count == 0
    end

    test "emits telemetry for failed manual publish" do
      attach_telemetry_handler([:leythers_com, :content, :manual_publish, :stop])

      assert {:error, _changeset} =
               Content.publish_article(
                 %{title: "", body: ""},
                 [UUID.generate(), UUID.generate(), UUID.generate(), UUID.generate()]
               )

      assert_receive {:telemetry_event, [:leythers_com, :content, :manual_publish, :stop],
                      measurements, metadata}

      assert measurements.duration > 0
      assert measurements.count == 1
      assert metadata.result == :error
      assert metadata.source_count == 4
      refute Map.has_key?(metadata, :article_id)
    end
  end

  describe "update_article/2" do
    test "increments version when editing a published article" do
      {:ok, article} =
        Content.create_article(%{
          slug: "versioned-published-article",
          title: "Published Article",
          body: "Initial body",
          status: "published",
          version: 1
        })

      assert {:ok, updated_article} =
               Content.update_article(article, %{title: "Updated Published Article"})

      assert updated_article.title == "Updated Published Article"
      assert updated_article.version == 2
    end

    test "does not increment version when editing a draft article" do
      {:ok, article} =
        Content.create_article(%{
          slug: "versioned-draft-article",
          title: "Draft Article",
          body: "Initial body",
          status: "draft",
          version: 1
        })

      assert {:ok, updated_article} =
               Content.update_article(article, %{title: "Updated Draft Article"})

      assert updated_article.title == "Updated Draft Article"
      assert updated_article.version == 1
    end
  end

  describe "delete_articles_by_slug_prefix/1" do
    test "deletes matching articles and returns the count" do
      {:ok, _article_a} =
        Content.create_article(%{
          slug: "smoke-test-article-a",
          title: "Smoke A",
          body: "Body A"
        })

      {:ok, _article_b} =
        Content.create_article(%{
          slug: "smoke-test-article-b",
          title: "Smoke B",
          body: "Body B"
        })

      {:ok, _article_other} =
        Content.create_article(%{
          slug: "keep-this-one",
          title: "Keep",
          body: "Body"
        })

      assert {:ok, 2} = Content.delete_articles_by_slug_prefix("smoke-test-")
      assert Repo.aggregate(PermanentArticle, :count, :id) == 1
    end

    test "returns error for blank prefix" do
      assert {:error, :invalid_prefix} = Content.delete_articles_by_slug_prefix("   ")
    end

    test "emits telemetry for cleanup attempts" do
      attach_telemetry_handler([:leythers_com, :content, :cleanup, :stop])

      assert {:error, :invalid_prefix} = Content.delete_articles_by_slug_prefix("   ")

      assert_receive {:telemetry_event, [:leythers_com, :content, :cleanup, :stop], measurements,
                      metadata}

      assert measurements.duration >= 0
      assert measurements.count == 1
      assert metadata.result == :error
      assert metadata.deleted_count == 0
    end
  end

  describe "delete_smoke_test_articles/0" do
    test "uses the smoke-test slug prefix" do
      {:ok, _article} =
        Content.create_article(%{
          slug: "smoke-test-article-default",
          title: "Smoke Default",
          body: "Body"
        })

      assert {:ok, 1} = Content.delete_smoke_test_articles()
      assert Repo.aggregate(PermanentArticle, :count, :id) == 0
    end
  end

  describe "list_recent_articles_with_sources/1" do
    test "returns recent articles with linked source provenance" do
      {:ok, source} =
        Ingestion.create_raw_source(%{
          title: "Overview Source",
          url: "https://example.com/overview-source",
          origin_provider: "rss",
          external_published_at: ~U[2026-06-20 10:00:00.000000Z]
        })

      {:ok, linked_article} =
        Content.publish_article(
          %{
            title: "Overview Linked Article",
            body: "Linked body"
          },
          [source.id]
        )

      {:ok, unlinked_article} =
        Content.publish_article(%{
          title: "Overview Unlinked Article",
          body: "Unlinked body"
        })

      entries = Content.list_recent_articles_with_sources(10)

      linked_entry = Enum.find(entries, fn entry -> entry.article.id == linked_article.id end)
      unlinked_entry = Enum.find(entries, fn entry -> entry.article.id == unlinked_article.id end)

      assert linked_entry
      assert length(linked_entry.sources) == 1
      assert hd(linked_entry.sources).title == "Overview Source"

      assert unlinked_entry
      assert unlinked_entry.sources == []
    end

    test "returns empty list for non-positive limits" do
      assert Content.list_recent_articles_with_sources(0) == []
    end
  end

  describe "publish_or_update_ai_article/3" do
    test "creates a new ai article with voice styling and rumour labeling" do
      source_id = create_source_id!("Leigh linked source", "https://example.com/ai-linked-source")

      assert {:ok, :created, article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh linked with surprise halfback",
                   body: "Reports suggest Leigh are exploring a move."
                 },
                 [source_id],
                 rumour: true
               )

      assert article.author_type == "ai_editor"
      assert String.starts_with?(article.title, "Rumour: ")
      assert article.body =~ "Rumour mill warning"
      assert article.body =~ "Terrace verdict"
    end

    test "updates recent matching ai article when change is not significant" do
      source_id = create_source_id!("Leigh update source", "https://example.com/ai-update-source")

      assert {:ok, :created, created_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh eye cup final boost",
                   body: "Initial version"
                 },
                 [source_id]
               )

      assert {:ok, :updated, updated_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh eye cup final boost as squad improves",
                   body: "Updated version"
                 },
                 [source_id]
               )

      assert updated_article.id == created_article.id
      assert updated_article.version == created_article.version + 1
      assert updated_article.body =~ "Updated version"
    end

    test "updates recent matching ai article for similar titles with different leading tokens" do
      source_id_one =
        create_source_id!(
          "Leigh Toulouse source one",
          "https://example.com/ai-similar-title-source-1"
        )

      source_id_two =
        create_source_id!(
          "Leigh Toulouse source two",
          "https://example.com/ai-similar-title-source-2"
        )

      assert {:ok, :created, created_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Super League: Leigh overcome Toulouse as Charnley scores four tries",
                   body: "Initial version"
                 },
                 [source_id_one]
               )

      assert {:ok, :updated, updated_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Charnley scores four tries as Leigh beat Toulouse",
                   body: "Updated version"
                 },
                 [source_id_two]
               )

      assert updated_article.id == created_article.id
      assert updated_article.version == created_article.version + 1
      assert count_article_sources(updated_article.id) == 2
    end

    test "updates same ai article for similar Charnley contract and playing future titles" do
      source_id_one =
        create_source_id!(
          "Charnley contract source",
          "https://example.com/ai-charnley-contract-source"
        )

      source_id_two =
        create_source_id!(
          "Charnley future source",
          "https://example.com/ai-charnley-future-source"
        )

      assert {:ok, :created, created_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title:
                     "Josh Charnley drops major contract hint as Leigh Leopards star confirms intentions to go round again",
                   body: "Initial contract hint version"
                 },
                 [source_id_one]
               )

      assert {:ok, :updated, updated_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title:
                     "Josh Charnley sends message to Leigh Leopards on playing future - Love Rugby League",
                   body: "Updated playing future version"
                 },
                 [source_id_two]
               )

      assert updated_article.id == created_article.id
      assert updated_article.version == created_article.version + 1
      assert count_article_sources(updated_article.id) == 2
    end

    test "creates a new ai article when change is significant" do
      source_id =
        create_source_id!("Leigh significant source", "https://example.com/ai-significant-source")

      assert {:ok, :created, first_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh set for another big night",
                   body: "Base story"
                 },
                 [source_id]
               )

      assert {:ok, :created, second_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh set for another big night with transfer twist",
                   body: "Significant shift"
                 },
                 [source_id],
                 significant_change: true
               )

      refute second_article.id == first_article.id
      assert second_article.version == 1
    end

    test "returns error when ai article has no source links" do
      assert {:error, :source_ids_required} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh unsupported source-less AI story",
                   body: "This should fail because source ids are required."
                 },
                 []
               )
    end
  end

  defp create_source_id!(title, url) do
    {:ok, source} =
      Ingestion.create_raw_source(%{
        title: title,
        url: url,
        origin_provider: "test_feed",
        external_published_at: DateTime.utc_now()
      })

    source.id
  end

  defp count_article_sources(article_id) do
    ArticleSource
    |> where([article_source], article_source.permanent_article_id == ^article_id)
    |> Repo.aggregate(:count, :id)
  end

  defp attach_telemetry_handler(event_name) do
    handler_id = "content-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
