defmodule LeythersCom.Content.AIEditorial do
  @moduledoc false

  import Ecto.Query

  alias LeythersCom.Content.ArticleLinks
  alias LeythersCom.Content.Articles
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Content.Slug
  alias LeythersCom.Content.Voice
  alias LeythersCom.Intelligence.StorySimilarity
  alias LeythersCom.Repo

  @ai_update_title_similarity_threshold 0.6

  def publish_or_update_ai_article(attrs, source_ids \\ [], opts \\ []) when is_map(attrs) do
    started_at = System.monotonic_time()
    triage_action = Keyword.get(opts, :triage_action, nil)
    target_article_id = Keyword.get(opts, :target_article_id, nil)
    rumour? = Keyword.get(opts, :rumour, false)
    recency_window_hours = Keyword.get(opts, :recency_window_hours, 72)

    headline = fetch_attr(attrs, :headline) || fetch_attr(attrs, :title) || ""
    summary = fetch_attr(attrs, :summary) || ""
    body = fetch_attr(attrs, :body_html) || fetch_attr(attrs, :body) || ""

    source_ids = source_ids |> Enum.reject(&blank?/1) |> Enum.map(&to_string/1) |> Enum.uniq()

    result =
      perform_article_publishing(
        {headline, summary, body},
        body,
        source_ids,
        triage_action,
        target_article_id,
        recency_window_hours,
        rumour?
      )

    finalized_result =
      case result do
        {:ok, {:created, article}} -> {:ok, :created, article}
        {:ok, {:updated, article}} -> {:ok, :updated, article}
        {:error, reason} -> {:error, reason}
      end

    emit_ai_editorial_telemetry(finalized_result, started_at, rumour?, triage_action == :new)
    finalized_result
  end

  defp perform_article_publishing(
         _parts,
         _raw_body,
         [],
         _triage_action,
         _target_article_id,
         _recency,
         _rumour
       ) do
    {:error, :source_ids_required}
  end

  defp perform_article_publishing(
         {headline, summary, body},
         raw_body,
         source_ids,
         triage_action,
         target_article_id,
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
            triage_action,
            target_article_id,
            recency_window_hours
          )
        end)

      {:error, voice_issues} ->
        {:error, {:voice_validation_failed, voice_issues}}
    end
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

    with {:ok, article} <- Articles.create_article(article_attrs),
         :ok <- ArticleLinks.insert_article_sources(article.id, source_ids) do
      {:created, article}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp publish_or_update_ai_decision(
         voiced_output,
         raw_body,
         source_ids,
         :new,
         _target_article_id,
         _recency_window_hours
       ) do
    create_ai_article(voiced_output, raw_body, source_ids)
  end

  defp publish_or_update_ai_decision(
         voiced_output,
         raw_body,
         source_ids,
         :update,
         target_article_id,
         recency_window_hours
       ) do
    case resolve_update_target(
           target_article_id,
           voiced_output.headline,
           recency_window_hours,
           source_ids
         ) do
      nil -> create_ai_article(voiced_output, raw_body, source_ids)
      article -> update_ai_article(article, voiced_output, raw_body, source_ids)
    end
  end

  defp publish_or_update_ai_decision(
         voiced_output,
         raw_body,
         source_ids,
         nil,
         target_article_id,
         recency_window_hours
       ) do
    case resolve_update_target(
           target_article_id,
           voiced_output.headline,
           recency_window_hours,
           source_ids
         ) do
      nil -> create_ai_article(voiced_output, raw_body, source_ids)
      article -> update_ai_article(article, voiced_output, raw_body, source_ids)
    end
  end

  defp resolve_update_target(target_article_id, headline, recency_window_hours, source_ids) do
    case fetch_published_article(target_article_id) do
      nil -> find_recent_matching_article(headline, recency_window_hours, source_ids)
      article -> article
    end
  end

  defp fetch_published_article(article_id) when is_binary(article_id) do
    case Repo.get(PermanentArticle, article_id) do
      %PermanentArticle{status: "published"} = article -> article
      _other -> nil
    end
  end

  defp fetch_published_article(_article_id), do: nil

  defp update_ai_article(article, voiced_output, raw_body, source_ids) do
    attrs = %{
      title: voiced_output.headline,
      summary: voiced_output.summary,
      body: voiced_output.body,
      raw_content_backup: raw_body,
      status: "published"
    }

    with {:ok, updated_article} <- Articles.update_article(article, attrs),
         :ok <- ArticleLinks.insert_missing_article_sources(updated_article.id, source_ids) do
      {:updated, updated_article}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp find_recent_matching_article(title, recency_window_hours, source_ids) do
    cutoff = DateTime.add(DateTime.utc_now(), -recency_window_hours * 3600, :second)

    recent_articles =
      PermanentArticle
      |> where([article], article.status == "published")
      |> where([article], article.updated_at >= ^cutoff)
      |> order_by([article], desc: article.updated_at)
      |> Repo.all()

    source_id_set = MapSet.new(source_ids)

    Enum.find(recent_articles, fn article ->
      StorySimilarity.similar?(article.title, title, @ai_update_title_similarity_threshold) or
        has_source_overlap?(article.id, source_id_set)
    end)
  end

  defp has_source_overlap?(article_id, source_id_set) do
    if MapSet.size(source_id_set) == 0 do
      false
    else
      article_id
      |> ArticleLinks.existing_source_ids_for_article()
      |> MapSet.new()
      |> MapSet.disjoint?(source_id_set)
      |> Kernel.not()
    end
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

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp blank?(value), do: value in [nil, ""]
end
