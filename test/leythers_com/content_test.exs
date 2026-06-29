defmodule LeythersCom.ContentTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Content
  alias LeythersCom.Content.PermanentArticle

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
        Content.get_article!(Ecto.UUID.generate())
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
end
