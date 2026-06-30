defmodule LeythersComWeb.PageController do
  use LeythersComWeb, :controller

  alias LeythersCom.Content
  alias LeythersCom.Intelligence.EditorialOrchestrator

  def home(conn, _params) do
    ranked_entries =
      case EditorialOrchestrator.latest_homepage_snapshot(12) do
        [] ->
          []

        snapshot ->
          snapshot
      end

    render(conn, :home, ranked_entries: ranked_entries)
  end

  def article(conn, %{"slug" => slug}) do
    case Content.get_article_with_sources_by_slug(slug) do
      {:ok, %{article: article, sources: sources}} ->
        render(conn, :article, article: article, sources: sources)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> text("Article not found")
    end
  end
end
