defmodule LeythersComWeb.PageControllerTest do
  use LeythersComWeb.ConnCase

  alias LeythersCom.Content
  alias LeythersCom.Ingestion
  alias LeythersCom.Intelligence.EditorialOrchestrator

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Leigh Leopards News and Rumours"
    assert html_response(conn, 200) =~ "No stories yet"
  end

  test "GET / renders ranked article cards when content exists", %{conn: conn} do
    {:ok, source} =
      Ingestion.create_raw_source(%{
        title: "Leigh match report",
        url: "https://example.com/leigh-match-report",
        body_summary: "Leigh edge a close one.",
        origin_provider: "test_feed",
        external_published_at: DateTime.utc_now()
      })

    {:ok, _article} =
      Content.publish_article(
        %{
          title: "Leopards Eye Late Kickoff Boost",
          summary: "Tight turnaround and key returnees shape Leigh plans.",
          body: "A lively update from the camp."
        },
        [source.id]
      )

    assert {:ok, %{decision_count: count}} =
             EditorialOrchestrator.refresh_homepage_layout(llm_enabled: false)

    assert count >= 1

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Leopards Eye Late Kickoff Boost"
    assert html =~ "Tight turnaround and key returnees shape Leigh plans."
    assert html =~ "score"
    assert html =~ "/articles/leopards-eye-late-kickoff-boost"
  end

  test "GET /articles/:slug renders headline and html article body only", %{conn: conn} do
    {:ok, source} =
      Ingestion.create_raw_source(%{
        title: "Leigh squad update",
        url: "https://example.com/leigh-squad-update",
        body_summary: "Injury return expected this week.",
        origin_provider: "test_feed",
        external_published_at: DateTime.utc_now()
      })

    {:ok, article} =
      Content.publish_article(
        %{
          title: "Leigh squad boost ahead of derby",
          summary: "Summary teaser for homepage cards.",
          body: "<p>Body copy for article detail page.</p>"
        },
        [source.id]
      )

    conn = get(conn, ~p"/articles/#{article.slug}")
    html = html_response(conn, 200)

    assert html =~ "Leigh squad boost ahead of derby"
    assert html =~ "Body copy for article detail page."
    refute html =~ "Source links"
    refute html =~ "Leigh squad update"
  end

  test "GET /articles/:slug returns not found for unknown slugs", %{conn: conn} do
    conn = get(conn, ~p"/articles/missing-story")
    assert response(conn, 404) =~ "Article not found"
  end
end
