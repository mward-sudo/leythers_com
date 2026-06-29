defmodule LeythersComWeb.PageController do
  use LeythersComWeb, :controller

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
end
