defmodule LeythersCom.Content.SlugTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Content
  alias LeythersCom.Content.Slug

  describe "generate/1" do
    test "lowercases and hyphenates a title" do
      assert Slug.generate("Leigh Leopards Win Again") == "leigh-leopards-win-again"
    end

    test "strips special characters" do
      assert Slug.generate("Leigh's 2026 Season!") == "leighs-2026-season"
    end

    test "collapses multiple hyphens" do
      assert Slug.generate("One  --  Two") == "one-two"
    end

    test "trims leading and trailing hyphens" do
      assert Slug.generate("  Grand Final  ") == "grand-final"
    end
  end

  describe "unique_for_title/1" do
    test "returns base slug when no collision" do
      assert {:ok, slug} = Slug.unique_for_title("New Article About Leigh")
      assert slug == "new-article-about-leigh"
    end

    test "appends -2 suffix on first collision" do
      {:ok, _} =
        Content.create_article(%{
          slug: "collision-test",
          title: "Collision Test",
          body: "body"
        })

      assert {:ok, slug} = Slug.unique_for_title("Collision Test")
      assert slug == "collision-test-2"
    end

    test "appends incrementing suffix on further collisions" do
      for suffix <- ["collision-series", "collision-series-2"] do
        Content.create_article(%{
          slug: suffix,
          title: "unused",
          body: "body"
        })
      end

      assert {:ok, slug} = Slug.unique_for_title("Collision Series")
      assert slug == "collision-series-3"
    end
  end
end
