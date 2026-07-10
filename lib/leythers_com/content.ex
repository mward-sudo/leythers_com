defmodule LeythersCom.Content do
  @moduledoc """
  Content context for creating and querying permanent articles.
  """

  alias LeythersCom.Content.AIEditorial
  alias LeythersCom.Content.ArticleLinks
  alias LeythersCom.Content.Articles
  alias LeythersCom.Content.Publishing
  alias LeythersCom.Content.Queries

  defdelegate create_article(attrs), to: Articles

  defdelegate update_article(article, attrs), to: Articles

  defdelegate publish_article(attrs, source_ids \\ []), to: Publishing

  defdelegate publish_or_update_ai_article(attrs, source_ids \\ [], opts \\ []),
    to: AIEditorial

  defdelegate get_article!(id), to: Articles

  defdelegate get_article_by_slug(slug), to: Articles

  defdelegate get_article_with_sources_by_slug(slug), to: Queries

  defdelegate list_articles(opts \\ []), to: Queries

  defdelegate list_recent_articles_with_sources(limit \\ 10), to: Queries

  defdelegate collapse_entries_to_story_fronts(entries), to: Queries

  defdelegate list_sources_for_article(article_id), to: ArticleLinks

  defdelegate delete_smoke_test_articles(), to: Publishing

  defdelegate delete_articles_by_slug_prefix(prefix), to: Publishing
end
