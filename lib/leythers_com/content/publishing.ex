defmodule LeythersCom.Content.Publishing do
  @moduledoc false

  import Ecto.Query

  alias LeythersCom.Content.ArticleLinks
  alias LeythersCom.Content.Articles
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Content.Slug
  alias LeythersCom.Repo

  def publish_article(attrs, source_ids \\ []) do
    started_at = System.monotonic_time()
    title = fetch_attr(attrs, :title) || ""
    body = fetch_attr(attrs, :body)
    summary = fetch_attr(attrs, :summary) || ""
    {:ok, slug} = Slug.unique_for_title(title)
    source_count = source_ids |> Enum.reject(&blank?/1) |> length()

    article_attrs = %{
      title: title,
      summary: summary,
      body: body,
      slug: slug,
      author_type: "human_admin",
      status: "published",
      version: 1
    }

    transaction_result =
      Repo.transaction(fn ->
        with {:ok, article} <- Articles.create_article(article_attrs),
             :ok <- ArticleLinks.insert_article_sources(article.id, source_ids) do
          article
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    result =
      case transaction_result do
        {:ok, article} -> {:ok, article}
        {:error, reason} -> {:error, reason}
      end

    emit_manual_publish_telemetry(result, started_at, source_count)
    result
  end

  def delete_smoke_test_articles do
    delete_articles_by_slug_prefix("smoke-test-")
  end

  def delete_articles_by_slug_prefix(prefix) when is_binary(prefix) do
    started_at = System.monotonic_time()
    trimmed_prefix = String.trim(prefix)

    if trimmed_prefix == "" do
      :telemetry.execute(
        [:leythers_com, :content, :cleanup, :stop],
        %{duration: System.monotonic_time() - started_at, count: 1},
        %{result: :error, deleted_count: 0}
      )

      {:error, :invalid_prefix}
    else
      query =
        from article in PermanentArticle,
          where: like(article.slug, ^"#{trimmed_prefix}%")

      {deleted_count, _} = Repo.delete_all(query)

      :telemetry.execute(
        [:leythers_com, :content, :cleanup, :stop],
        %{duration: System.monotonic_time() - started_at, count: 1},
        %{result: :ok, deleted_count: deleted_count}
      )

      {:ok, deleted_count}
    end
  end

  defp emit_manual_publish_telemetry(result, started_at, source_count) do
    metadata =
      case result do
        {:ok, article} ->
          %{result: :ok, article_id: article.id, source_count: source_count}

        {:error, _reason} ->
          %{result: :error, source_count: source_count}
      end

    :telemetry.execute(
      [:leythers_com, :content, :manual_publish, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      metadata
    )
  end

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp blank?(value), do: value in [nil, ""]
end
