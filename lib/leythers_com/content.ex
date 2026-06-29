defmodule LeythersCom.Content do
  @moduledoc """
  Content context for creating and querying permanent articles.
  """

  alias LeythersCom.Content.ArticleSource
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Content.Slug
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Repo

  def create_article(attrs) do
    %PermanentArticle{}
    |> PermanentArticle.changeset(attrs)
    |> Repo.insert()
  end

  def update_article(%PermanentArticle{} = article, attrs) when is_map(attrs) do
    attrs = maybe_increment_article_version(article, attrs)

    article
    |> PermanentArticle.changeset(attrs)
    |> Repo.update()
  end

  def publish_article(attrs, source_ids \\ []) do
    started_at = System.monotonic_time()
    title = fetch_attr(attrs, :title) || ""
    body = fetch_attr(attrs, :body)
    {:ok, slug} = Slug.unique_for_title(title)
    source_count = source_ids |> Enum.reject(&blank?/1) |> length()

    article_attrs = %{
      title: title,
      body: body,
      slug: slug,
      author_type: "human_admin",
      status: "published",
      version: 1
    }

    transaction_result =
      Repo.transaction(fn ->
        with {:ok, article} <- create_article(article_attrs),
             :ok <- insert_article_sources(article.id, source_ids) do
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

  def get_article!(id), do: Repo.get!(PermanentArticle, id)

  def get_article_by_slug(slug) do
    case Repo.get_by(PermanentArticle, slug: slug) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  def list_articles(opts \\ []) do
    import Ecto.Query

    PermanentArticle
    |> maybe_filter_status(opts[:status])
    |> Repo.all()
  end

  def list_recent_articles_with_sources(limit \\ 10)

  def list_recent_articles_with_sources(limit) when is_integer(limit) and limit > 0 do
    started_at = System.monotonic_time()
    import Ecto.Query

    articles =
      PermanentArticle
      |> order_by([article], desc: article.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    entries =
      Enum.map(articles, fn article ->
        %{article: article, sources: list_sources_for_article(article.id)}
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
      import Ecto.Query

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

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    import Ecto.Query
    where(query, [a], a.status == ^status)
  end

  defp insert_article_sources(_article_id, []), do: :ok

  defp insert_article_sources(article_id, source_ids) do
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

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp maybe_increment_article_version(
         %PermanentArticle{status: "published", version: version},
         attrs
       )
       when is_integer(version) do
    put_version_update(attrs, version + 1)
  end

  defp maybe_increment_article_version(_article, attrs), do: attrs

  defp put_version_update(attrs, next_version) when map_size(attrs) == 0 do
    Map.put(attrs, :version, next_version)
  end

  defp put_version_update(attrs, next_version) do
    keys = Map.keys(attrs)

    cond do
      Enum.all?(keys, &is_atom/1) ->
        Map.put(attrs, :version, next_version)

      Enum.all?(keys, &is_binary/1) ->
        Map.put(attrs, "version", next_version)

      true ->
        attrs
        |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
        |> Map.put("version", next_version)
    end
  end

  defp list_sources_for_article(article_id) do
    import Ecto.Query

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
        last_check_status: raw_source.last_check_status
      }
    )
    |> Repo.all()
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

  defp blank?(value), do: value in [nil, ""]
end
