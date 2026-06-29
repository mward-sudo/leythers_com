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
  end

  defp count_article_sources(article_id) do
    ArticleSource
    |> where([article_source], article_source.permanent_article_id == ^article_id)
    |> Repo.aggregate(:count, :id)
  end
end
