defmodule LeythersComWeb.Admin.ArticlePublishLiveTest do
  use LeythersComWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias LeythersCom.Content
  alias LeythersCom.Ingestion
  alias LeythersCom.Repo

  describe "new/0" do
    test "renders the manual publish form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/articles/new")

      assert html =~ "Manual Article Publish"
      assert has_element?(view, "#article-publish-form")
      assert has_element?(view, "#article-title")
      assert has_element?(view, "#article-body")
      assert has_element?(view, "#article-source-ids")
    end

    test "publishes an article without source links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/articles/new")

      form = element(view, "#article-publish-form")

      assert render_submit(form, %{
               "article" => %{
                 "title" => "Live Manual Publish",
                 "body" => "Published from the admin form.",
                 "source_ids" => ""
               }
             })

      assert render(view) =~ "Published article: live-manual-publish"
      assert {:ok, article} = Content.get_article_by_slug("live-manual-publish")
      assert article.status == "published"
    end

    test "publishes an article with selected source links", %{conn: conn} do
      {:ok, source_a} =
        Ingestion.create_raw_source(%{
          title: "Live Source A",
          url: "https://example.com/live-source-a",
          origin_provider: "rss",
          external_published_at: ~U[2026-06-01 10:00:00.000000Z]
        })

      {:ok, source_b} =
        Ingestion.create_raw_source(%{
          title: "Live Source B",
          url: "https://example.com/live-source-b",
          origin_provider: "rss",
          external_published_at: ~U[2026-06-01 11:00:00.000000Z]
        })

      {:ok, view, _html} = live(conn, ~p"/admin/articles/new")

      form = element(view, "#article-publish-form")

      assert render_submit(form, %{
               "article" => %{
                 "title" => "Live Linked Publish",
                 "body" => "Published with links.",
                 "source_ids" => "#{source_a.id}\n#{source_b.id}"
               }
             })

      assert {:ok, article} = Content.get_article_by_slug("live-linked-publish")
      assert source_link_count(article.id) == 2
    end
  end

  defp source_link_count(article_id) do
    from(article_source in LeythersCom.Content.ArticleSource,
      where: article_source.permanent_article_id == ^article_id
    )
    |> Repo.aggregate(:count, :id)
  end
end
