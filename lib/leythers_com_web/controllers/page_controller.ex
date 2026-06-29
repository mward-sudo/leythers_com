defmodule LeythersComWeb.PageController do
  use LeythersComWeb, :controller

  alias LeythersCom.Content
  alias LeythersCom.Intelligence.EditorialOrchestrator
  alias LeythersCom.Intelligence.HomepageRanker

  def home(conn, _params) do
    ranked_entries =
      case EditorialOrchestrator.latest_homepage_snapshot(12) do
        [] ->
          Content.list_recent_articles_with_sources(20)
          |> HomepageRanker.rank()
          |> Enum.take(12)

        snapshot ->
          snapshot
      end

    render(conn, :home, ranked_entries: ranked_entries)
  end
end
