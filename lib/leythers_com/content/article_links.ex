defmodule LeythersCom.Content.ArticleLinks do
  @moduledoc false

  import Ecto.Query

  alias LeythersCom.Content.ArticleSource
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Repo

  def list_sources_for_article(article_id) when is_binary(article_id) do
    from(article_source in ArticleSource,
      join: raw_source in RawSource,
      on: article_source.raw_source_id == raw_source.id,
      where: article_source.permanent_article_id == ^article_id,
      order_by: [asc: raw_source.inserted_at],
      select: %{
        id: raw_source.id,
        title: raw_source.title,
        url: raw_source.url,
        origin_provider: raw_source.origin_provider,
        last_check_status: raw_source.last_check_status,
        external_published_at: raw_source.external_published_at
      }
    )
    |> Repo.all()
  end

  def list_sources_for_article(_article_id), do: []

  def insert_article_sources(_article_id, []), do: :ok

  def insert_article_sources(article_id, source_ids) do
    source_ids
    |> Enum.reject(&blank?/1)
    |> Enum.map(&to_string/1)
    |> Enum.reduce_while(:ok, fn raw_source_id, :ok ->
      article_source_changeset =
        ArticleSource.changeset(%ArticleSource{}, %{
          permanent_article_id: article_id,
          raw_source_id: raw_source_id
        })

      case Repo.insert(article_source_changeset) do
        {:ok, _article_source} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  def insert_missing_article_sources(_article_id, []), do: :ok

  def insert_missing_article_sources(article_id, source_ids) do
    existing_ids = existing_source_ids_for_article(article_id)

    source_ids
    |> Enum.reject(&(&1 in existing_ids))
    |> then(&insert_article_sources(article_id, &1))
  end

  def existing_source_ids_for_article(article_id) when is_binary(article_id) do
    from(article_source in ArticleSource,
      where: article_source.permanent_article_id == ^article_id,
      select: article_source.raw_source_id
    )
    |> Repo.all()
  end

  def existing_source_ids_for_article(_article_id), do: []

  defp blank?(value), do: value in [nil, ""]
end
