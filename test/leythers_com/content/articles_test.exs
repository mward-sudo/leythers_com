defmodule LeythersCom.Content.ArticlesTest do
  use LeythersCom.DataCase, async: true

  alias Ecto.UUID
  alias LeythersCom.Content
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Content.Story

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

    test "assigns a story when not provided" do
      assert {:ok, %PermanentArticle{} = article} = Content.create_article(@valid_attrs)
      assert article.story_id

      assert %Story{} = Repo.get!(Story, article.story_id)
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
end
