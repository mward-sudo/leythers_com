defmodule LeythersComWeb.PageController do
  use LeythersComWeb, :controller

  alias LeythersCom.Content
  alias LeythersCom.Intelligence.HomepageRanker

  def home(conn, _params) do
    ranked_entries =
      Content.list_recent_articles_with_sources(20)
      |> HomepageRanker.rank()
      |> Enum.take(12)

    render(conn, :home, ranked_entries: ranked_entries)
  end
end
