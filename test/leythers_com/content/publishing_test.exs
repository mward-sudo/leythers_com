defmodule LeythersCom.Content.PublishingTest do
  use LeythersCom.DataCase, async: true

  alias Ecto.UUID
  alias LeythersCom.Content
  alias LeythersCom.Content.ArticleSource
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Ingestion

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
      handler_id =
        attach_telemetry_handler(self(), [:leythers_com, :content, :manual_publish, :stop])

      on_exit(fn -> :telemetry.detach(handler_id) end)

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
      handler_id =
        attach_telemetry_handler(self(), [:leythers_com, :content, :manual_publish, :stop])

      on_exit(fn -> :telemetry.detach(handler_id) end)

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
      handler_id = attach_telemetry_handler(self(), [:leythers_com, :content, :cleanup, :stop])

      on_exit(fn -> :telemetry.detach(handler_id) end)

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

  defp count_article_sources(article_id) do
    ArticleSource
    |> where([article_source], article_source.permanent_article_id == ^article_id)
    |> Repo.aggregate(:count, :id)
  end

  defp attach_telemetry_handler(test_pid, event_name) do
    handler_id = "content-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, measurements, metadata})
        end,
        test_pid
      )

    handler_id
  end
end
