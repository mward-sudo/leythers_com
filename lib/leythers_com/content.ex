defmodule LeythersCom.Content do
  @moduledoc """
  Content context for creating and querying permanent articles.
  """

  alias LeythersCom.Content.ArticleSource
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Content.Slug
  alias LeythersCom.Content.Voice
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Intelligence.StorySimilarity
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

  def publish_or_update_ai_article(attrs, source_ids \\ [], opts \\ []) when is_map(attrs) do
    started_at = System.monotonic_time()
    significant_change? = Keyword.get(opts, :significant_change, false)
    rumour? = Keyword.get(opts, :rumour, false)
    recency_window_hours = Keyword.get(opts, :recency_window_hours, 36)

    # Support both 3-part structure (headline/summary/body) and legacy (title/body)
    headline = fetch_attr(attrs, :headline) || fetch_attr(attrs, :title) || ""
    summary = fetch_attr(attrs, :summary) || ""
    body = fetch_attr(attrs, :body) || ""

    source_ids = source_ids |> Enum.reject(&blank?/1) |> Enum.map(&to_string/1) |> Enum.uniq()

    result =
      perform_article_publishing(
        {headline, summary, body},
        body,
        source_ids,
        significant_change?,
        recency_window_hours,
        rumour?
      )

    finalized_result =
      case result do
        {:ok, {:created, article}} -> {:ok, :created, article}
        {:ok, {:updated, article}} -> {:ok, :updated, article}
        {:error, reason} -> {:error, reason}
      end

    emit_ai_editorial_telemetry(finalized_result, started_at, rumour?, significant_change?)
    finalized_result
  end

  defp perform_article_publishing(_parts, _raw_body, [], _significant, _recency, _rumour) do
    {:error, :source_ids_required}
  end

  defp perform_article_publishing(
         {headline, summary, body},
         raw_body,
         source_ids,
         significant_change?,
         recency_window_hours,
         rumour?
       ) do
    case Voice.apply_to_output(
           %{headline: headline, summary: summary, body: body},
           rumour: rumour?
         ) do
      {:ok, voiced_output} ->
        Repo.transaction(fn ->
          publish_or_update_ai_decision(
            voiced_output,
            raw_body,
            source_ids,
            significant_change?,
            recency_window_hours
          )
        end)

      {:error, voice_issues} ->
        {:error, {:voice_validation_failed, voice_issues}}
    end
  end

  def get_article!(id), do: Repo.get!(PermanentArticle, id)

  def get_article_by_slug(slug) do
    case Repo.get_by(PermanentArticle, slug: slug) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  def get_article_with_sources_by_slug(slug) do
    with {:ok, article} <- get_article_by_slug(slug) do
      {:ok, %{article: article, sources: list_sources_for_article(article.id)}}
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

  def list_sources_for_article(article_id) when is_binary(article_id) do
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
        last_check_status: raw_source.last_check_status,
        external_published_at: raw_source.external_published_at
      }
    )
    |> Repo.all()
  end

  def list_sources_for_article(_article_id), do: []

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

  defp create_ai_article(voiced_output, raw_body, source_ids) do
    {:ok, slug} = Slug.unique_for_title(voiced_output.headline)

    article_attrs = %{
      title: voiced_output.headline,
      summary: voiced_output.summary,
      body: voiced_output.body,
      slug: slug,
      author_type: "ai_editor",
      status: "published",
      version: 1,
      raw_content_backup: raw_body
    }

    with {:ok, article} <- create_article(article_attrs),
         :ok <- insert_article_sources(article.id, source_ids) do
      {:created, article}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp publish_or_update_ai_decision(
         voiced_output,
         raw_body,
         source_ids,
         true,
         recency_window_hours
       ) do
    case find_recent_matching_ai_article(voiced_output.headline, recency_window_hours, source_ids) do
      nil -> create_ai_article(voiced_output, raw_body, source_ids)
      article -> update_ai_article(article, voiced_output, raw_body, source_ids)
    end
  end

  defp publish_or_update_ai_decision(
         voiced_output,
         raw_body,
         source_ids,
         false,
         recency_window_hours
       ) do
    case find_recent_matching_ai_article(voiced_output.headline, recency_window_hours, source_ids) do
      nil -> create_ai_article(voiced_output, raw_body, source_ids)
      article -> update_ai_article(article, voiced_output, raw_body, source_ids)
    end
  end

  defp update_ai_article(article, voiced_output, raw_body, source_ids) do
    attrs = %{
      title: voiced_output.headline,
      summary: voiced_output.summary,
      body: voiced_output.body,
      raw_content_backup: raw_body,
      status: "published"
    }

    with {:ok, updated_article} <- update_article(article, attrs),
         :ok <- insert_missing_article_sources(updated_article.id, source_ids) do
      {:updated, updated_article}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_missing_article_sources(_article_id, []), do: :ok

  defp insert_missing_article_sources(article_id, source_ids) do
    existing_ids = existing_source_ids_for_article(article_id)

    source_ids
    |> Enum.reject(&(&1 in existing_ids))
    |> then(&insert_article_sources(article_id, &1))
  end

  defp existing_source_ids_for_article(article_id) when is_binary(article_id) do
    import Ecto.Query

    from(article_source in ArticleSource,
      where: article_source.permanent_article_id == ^article_id,
      select: article_source.raw_source_id
    )
    |> Repo.all()
  end

  defp existing_source_ids_for_article(_article_id), do: []

  defp find_recent_matching_ai_article(title, recency_window_hours, source_ids) do
    import Ecto.Query

    cutoff = DateTime.add(DateTime.utc_now(), -recency_window_hours * 3600, :second)

    recent_articles =
      PermanentArticle
      |> where([article], article.author_type == "ai_editor")
      |> where([article], article.status == "published")
      |> where([article], article.updated_at >= ^cutoff)
      |> order_by([article], desc: article.updated_at)
      |> Repo.all()

    source_id_set = MapSet.new(source_ids)

    Enum.find(recent_articles, fn article ->
      StorySimilarity.similar?(article.title, title) or
        has_source_overlap?(article.id, source_id_set)
    end)
  end

  defp has_source_overlap?(article_id, source_id_set) do
    if MapSet.size(source_id_set) == 0 do
      false
    else
      article_id
      |> existing_source_ids_for_article()
      |> MapSet.new()
      |> MapSet.disjoint?(source_id_set)
      |> Kernel.not()
    end
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

  defp emit_ai_editorial_telemetry(result, started_at, rumour?, significant_change?) do
    metadata =
      case result do
        {:ok, action, article} ->
          %{
            result: :ok,
            action: action,
            article_id: article.id,
            rumour: rumour?,
            significant_change: significant_change?
          }

        {:error, _reason} ->
          %{result: :error, rumour: rumour?, significant_change: significant_change?}
      end

    :telemetry.execute(
      [:leythers_com, :content, :ai_editorial, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      metadata
    )
  end

  defp blank?(value), do: value in [nil, ""]
end
