defmodule LeythersCom.Content.Queries do
  @moduledoc false

  import Ecto.Query

  alias LeythersCom.Content.ArticleLinks
  alias LeythersCom.Content.Articles
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Repo

  def get_article_with_sources_by_slug(slug) do
    with {:ok, article} <- Articles.get_article_by_slug(slug) do
      {:ok, %{article: article, sources: ArticleLinks.list_sources_for_article(article.id)}}
    end
  end

  def list_articles(opts \\ []) do
    PermanentArticle
    |> maybe_filter_status(opts[:status])
    |> Repo.all()
  end

  def list_recent_articles_with_sources(limit \\ 10)

  def list_recent_articles_with_sources(limit) when is_integer(limit) and limit > 0 do
    started_at = System.monotonic_time()

    articles =
      PermanentArticle
      |> order_by([article], desc: article.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    entries =
      Enum.map(articles, fn article ->
        %{article: article, sources: ArticleLinks.list_sources_for_article(article.id)}
      end)

    :telemetry.execute(
      [:leythers_com, :content, :provenance_history, :query, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{result: :ok, article_count: length(entries)}
    )

    entries
  end

  def list_recent_articles_with_sources(_limit) do
    :telemetry.execute(
      [:leythers_com, :content, :provenance_history, :query, :stop],
      %{duration: 0, count: 1},
      %{result: :invalid_limit, article_count: 0}
    )

    []
  end

  def collapse_entries_to_story_fronts(entries) when is_list(entries) do
    entries
    |> Enum.group_by(fn entry ->
      entry.article.story_id || entry.article.id
    end)
    |> Enum.map(fn {_story_key, story_entries} ->
      Enum.max_by(
        story_entries,
        fn entry ->
          entry.article.updated_at || entry.article.inserted_at
        end,
        DateTime
      )
    end)
  end

  def collapse_entries_to_story_fronts(_entries), do: []

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    where(query, [article], article.status == ^status)
  end
end
