defmodule LeythersComWeb.PageController do
  use LeythersComWeb, :controller

  alias LeythersCom.Content
  alias LeythersCom.Intelligence.EditorialOrchestrator
  alias LeythersCom.Intelligence.HomepageRanker

  @homepage_size 12

  def home(conn, _params) do
    ranked_entries =
      @homepage_size
      |> EditorialOrchestrator.latest_homepage_snapshot()
      |> with_fallback_entries(@homepage_size)

    render(conn, :home, ranked_entries: ranked_entries)
  end

  def article(conn, %{"slug" => slug}) do
    case Content.get_article_with_sources_by_slug(slug) do
      {:ok, %{article: article}} ->
        render(conn, :article, article: article)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> text("Article not found")
    end
  end

  defp with_fallback_entries(snapshot, desired_count)
       when is_list(snapshot) and is_integer(desired_count) and desired_count > 0 do
    if length(snapshot) >= desired_count do
      Enum.take(snapshot, desired_count)
    else
      snapshot_ids = snapshot |> Enum.map(& &1.article.id) |> MapSet.new()

      fallback_entries =
        (desired_count * 3)
        |> Content.list_recent_articles_with_sources()
        |> HomepageRanker.rank(llm_enabled: false)
        |> Enum.reject(&MapSet.member?(snapshot_ids, &1.article.id))
        |> Enum.take(desired_count - length(snapshot))

      snapshot ++ fallback_entries
    end
  end

  defp with_fallback_entries(_snapshot, _desired_count), do: []
end
