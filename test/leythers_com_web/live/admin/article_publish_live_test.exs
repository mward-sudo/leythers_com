defmodule LeythersComWeb.Admin.ArticlePublishLiveTest do
  use LeythersComWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias LeythersCom.Content
  alias LeythersCom.Ingestion
  alias LeythersCom.Repo

  describe "authentication" do
    test "redirects unauthenticated users to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/articles/new")
      assert path =~ "/users/log-in"
    end
  end

  describe "new/0" do
    setup :register_and_log_in_user

    test "renders the manual publish form", %{conn: conn, user: _user} do
      {:ok, view, html} = live(conn, ~p"/admin/articles/new")

      assert html =~ "Manual Article Publish"
      assert has_element?(view, "#article-publish-form")
      assert has_element?(view, "#article-title")
      assert has_element?(view, "#article-body")
      assert has_element?(view, "#article-source-ids")
    end

    test "publishes an article without source links", %{conn: conn, user: _user} do
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

    test "publishes an article with selected source links", %{conn: conn, user: _user} do
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

    test "shows validation errors when required fields are empty", %{conn: conn, user: _user} do
      {:ok, view, _html} = live(conn, ~p"/admin/articles/new")

      assert render_change(element(view, "#article-publish-form"), %{
               "article" => %{"title" => "", "body" => "", "source_ids" => ""}
             })

      assert has_element?(view, "#article-publish-form", "can't be blank")
    end

    test "shows source id format validation errors", %{conn: conn, user: _user} do
      {:ok, view, _html} = live(conn, ~p"/admin/articles/new")

      assert render_change(element(view, "#article-publish-form"), %{
               "article" => %{
                 "title" => "Manual Source Validation",
                 "body" => "Validate source IDs",
                 "source_ids" => "not-a-uuid"
               }
             })

      assert has_element?(
               view,
               "#article-publish-form",
               "must contain valid UUIDs separated by commas or new lines"
             )
    end

    test "cleanup tool deletes smoke-test articles by slug prefix", %{conn: conn, user: _user} do
      {:ok, _smoke_article} =
        Content.create_article(%{
          slug: "smoke-test-live-cleanup",
          title: "Smoke Cleanup",
          body: "cleanup me"
        })

      {:ok, _keep_article} =
        Content.create_article(%{slug: "keep-live-cleanup", title: "Keep", body: "keep me"})

      {:ok, view, _html} = live(conn, ~p"/admin/articles/new")

      assert render_submit(element(view, "#article-cleanup-form"), %{
               "cleanup" => %{"slug_prefix" => "smoke-test-"}
             })

      assert {:error, :not_found} = Content.get_article_by_slug("smoke-test-live-cleanup")
      assert {:ok, _article} = Content.get_article_by_slug("keep-live-cleanup")
      assert has_element?(view, "#flash-info", "Deleted 1 matching article(s)")
    end
  end

  defp source_link_count(article_id) do
    from(article_source in LeythersCom.Content.ArticleSource,
      where: article_source.permanent_article_id == ^article_id
    )
    |> Repo.aggregate(:count, :id)
  end
end
