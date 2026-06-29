defmodule LeythersComWeb.PageControllerTest do
  use LeythersComWeb.ConnCase

  alias LeythersCom.Content

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Leigh Leopards News and Rumours"
    assert html_response(conn, 200) =~ "No stories yet"
  end

  test "GET / renders ranked article cards when content exists", %{conn: conn} do
    {:ok, _article} =
      Content.create_article(%{
        slug: "home-page-test-article",
        title: "Leopards Eye Late Kickoff Boost",
        body: "A lively update from the camp.",
        author_type: "ai_editor",
        status: "published"
      })

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Leopards Eye Late Kickoff Boost"
    assert html =~ "score"
  end
end
