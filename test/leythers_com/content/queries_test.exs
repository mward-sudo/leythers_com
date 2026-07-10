defmodule LeythersCom.Content.QueriesTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Content
  alias LeythersCom.Content.Story
  alias LeythersCom.Ingestion

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

  describe "collapse_entries_to_story_fronts/1" do
    test "returns only the newest article entry for each story" do
      {:ok, story} =
        %Story{}
        |> Story.changeset(%{headline: "Leigh Leopards storyline"})
        |> Repo.insert()

      {:ok, older_article} =
        Content.create_article(%{
          slug: "story-front-older",
          title: "Older headline",
          body: "Older body",
          story_id: story.id
        })

      {:ok, newer_article} =
        Content.create_article(%{
          slug: "story-front-newer",
          title: "Newer headline",
          body: "Newer body",
          story_id: story.id
        })

      entries = [
        %{article: older_article, sources: []},
        %{article: newer_article, sources: []}
      ]

      collapsed = Content.collapse_entries_to_story_fronts(entries)

      assert length(collapsed) == 1
      assert hd(collapsed).article.id == newer_article.id
    end
  end
end
