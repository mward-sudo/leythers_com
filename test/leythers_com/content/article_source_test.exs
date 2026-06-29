defmodule LeythersCom.Content.ArticleSourceTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Content.ArticleSource

  @valid_attrs %{
    permanent_article_id: Ecto.UUID.generate(),
    raw_source_id: Ecto.UUID.generate()
  }

  describe "changeset/2 with valid attributes" do
    test "returns a valid changeset with both IDs" do
      assert %Ecto.Changeset{valid?: true} =
               ArticleSource.changeset(%ArticleSource{}, @valid_attrs)
    end

    test "returns a valid changeset with nil raw_source_id" do
      attrs = Map.put(@valid_attrs, :raw_source_id, nil)
      assert %Ecto.Changeset{valid?: true} = ArticleSource.changeset(%ArticleSource{}, attrs)
    end
  end

  describe "changeset/2 required fields" do
    test "rejects missing permanent_article_id" do
      attrs = Map.delete(@valid_attrs, :permanent_article_id)
      changeset = ArticleSource.changeset(%ArticleSource{}, attrs)
      assert %{permanent_article_id: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
