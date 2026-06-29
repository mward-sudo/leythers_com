defmodule LeythersCom.Content.PermanentArticleTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Content.PermanentArticle

  @valid_attrs %{
    slug: "leigh-leopards-win-grand-final",
    title: "Leigh Leopards Win Grand Final",
    body: "The Leigh Leopards claimed victory in a thrilling final."
  }

  describe "changeset/2 with valid attributes" do
    test "returns a valid changeset" do
      assert %Ecto.Changeset{valid?: true} =
               PermanentArticle.changeset(%PermanentArticle{}, @valid_attrs)
    end

    test "accepts optional raw_content_backup" do
      attrs = Map.put(@valid_attrs, :raw_content_backup, "raw llm output")

      assert %Ecto.Changeset{valid?: true} =
               PermanentArticle.changeset(%PermanentArticle{}, attrs)
    end
  end

  describe "changeset/2 required fields" do
    test "rejects missing slug" do
      attrs = Map.delete(@valid_attrs, :slug)
      changeset = PermanentArticle.changeset(%PermanentArticle{}, attrs)
      assert %{slug: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing title" do
      attrs = Map.delete(@valid_attrs, :title)
      changeset = PermanentArticle.changeset(%PermanentArticle{}, attrs)
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing body" do
      attrs = Map.delete(@valid_attrs, :body)
      changeset = PermanentArticle.changeset(%PermanentArticle{}, attrs)
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "changeset/2 author_type field" do
    test "defaults to ai_editor" do
      changeset = PermanentArticle.changeset(%PermanentArticle{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :author_type) == "ai_editor"
    end

    test "accepts valid author_type values" do
      for author_type <- ~w[ai_editor human_admin] do
        attrs = Map.put(@valid_attrs, :author_type, author_type)

        assert %Ecto.Changeset{valid?: true} =
                 PermanentArticle.changeset(%PermanentArticle{}, attrs)
      end
    end

    test "rejects invalid author_type" do
      attrs = Map.put(@valid_attrs, :author_type, "robot")
      changeset = PermanentArticle.changeset(%PermanentArticle{}, attrs)
      assert %{author_type: [_]} = errors_on(changeset)
    end
  end

  describe "changeset/2 status field" do
    test "defaults to published" do
      changeset = PermanentArticle.changeset(%PermanentArticle{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == "published"
    end

    test "accepts valid status values" do
      for status <- ~w[draft published] do
        attrs = Map.put(@valid_attrs, :status, status)

        assert %Ecto.Changeset{valid?: true} =
                 PermanentArticle.changeset(%PermanentArticle{}, attrs)
      end
    end

    test "rejects invalid status" do
      attrs = Map.put(@valid_attrs, :status, "archived")
      changeset = PermanentArticle.changeset(%PermanentArticle{}, attrs)
      assert %{status: [_]} = errors_on(changeset)
    end
  end

  describe "changeset/2 version field" do
    test "defaults to 1" do
      changeset = PermanentArticle.changeset(%PermanentArticle{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :version) == 1
    end

    test "rejects version below 1" do
      attrs = Map.put(@valid_attrs, :version, 0)
      changeset = PermanentArticle.changeset(%PermanentArticle{}, attrs)
      assert %{version: [_]} = errors_on(changeset)
    end
  end
end
