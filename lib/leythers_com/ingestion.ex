defmodule LeythersCom.Ingestion do
  @moduledoc """
  Ingestion context for creating and querying normalized raw sources.
  """

  import Ecto.Query

  alias LeythersCom.Content.ArticleSource
  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Ingestion.ArticleContentFetcher
  alias LeythersCom.Ingestion.FetchRssFeedWorker
  alias LeythersCom.Ingestion.HttpClient.Req
  alias LeythersCom.Ingestion.Providers.Basic
  alias LeythersCom.Ingestion.Providers.Rss
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Intelligence.EditorialOrchestrator
  alias LeythersCom.Intelligence.SourceEditorialWorker
  alias LeythersCom.Repo

  @recent_regeneration_window_days 14

  def create_raw_source(attrs) do
    attrs
    |> Basic.normalize()
    |> then(&(%RawSource{} |> RawSource.changeset(&1)))
    |> Repo.insert()
  end

  def upsert_raw_source(attrs) do
    attrs = Basic.normalize(attrs)
    url = Map.get(attrs, :url) || Map.get(attrs, "url")

    changeset = RawSource.changeset(%RawSource{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :url) do
      {:ok, _} ->
        source = Repo.get_by!(RawSource, url: url)
        _ = EditorialOrchestrator.trigger_source_update_refresh()
        {:ok, source}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_raw_source!(id), do: Repo.get!(RawSource, id)

  def list_raw_sources(opts \\ []) do
    RawSource
    |> maybe_filter_status(opts[:status])
    |> Repo.all()
  end

  def record_raw_source_health(%RawSource{} = raw_source, attrs) when is_map(attrs) do
    raw_source
    |> RawSource.changeset(Basic.normalize(attrs))
    |> Repo.update()
  end

  def ingest_rss_feed(attrs, http_client \\ Req) when is_map(attrs) do
    started_at = System.monotonic_time()
    attrs = Basic.normalize(attrs)
    feed_url = Map.get(attrs, "url")
    origin_provider = Map.get(attrs, "origin_provider")
    include_keywords = Map.get(attrs, "include_keywords", [])

    result =
      cond do
        blank?(feed_url) ->
          {:error, :missing_url}

        blank?(origin_provider) ->
          {:error, :missing_origin_provider}

        true ->
          ingest_feed_items(feed_url, origin_provider, include_keywords, http_client)
      end

    emit_feed_ingestion_telemetry(result, started_at, origin_provider, feed_url)

    maybe_enqueue_editorial_generation(result)

    result
  end

  def ingest_configured_feeds do
    :leythers_com
    |> Application.get_env(:ingestion_feeds, [])
    |> Enum.map(&enqueue_feed_fetch/1)
  end

  def enqueue_feed_fetch(attrs) when is_map(attrs) do
    enqueue_feed_fetch(attrs, force: false)
  end

  def enqueue_feed_fetch(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs
    |> Basic.normalize()
    |> FetchRssFeedWorker.new(unique: maybe_feed_unique_opts(opts))
    |> Oban.insert()
  end

  def enqueue_article_regeneration(scope, opts \\ [])

  def enqueue_article_regeneration(scope, opts) when scope in [:all, :recent] do
    now = opts[:now] || DateTime.utc_now()
    enqueue_worker? = Keyword.get(opts, :enqueue_worker, regeneration_enqueue_worker?())

    requeued_sources =
      RawSource
      |> where([source], source.status in ["processed", "ignored"])
      |> maybe_filter_regeneration_scope(scope, now)
      |> Repo.update_all(set: [status: "pending"])
      |> elem(0)

    {:ok, maybe_enqueue_source_editorial_worker(requeued_sources, scope, enqueue_worker?)}
  end

  def enqueue_article_regeneration(_scope, _opts), do: {:error, :invalid_scope}

  def reset_article_and_source_data(opts \\ []) do
    enqueue_feeds? = Keyword.get(opts, :enqueue_feeds, true)
    enqueue_fun = Keyword.get(opts, :enqueue_fun, &enqueue_feed_fetch_for_reset/1)
    feeds = Keyword.get(opts, :feeds, configured_feeds())

    with {:ok, delete_stats} <- delete_article_and_source_rows(),
         {:ok, enqueue_stats} <- enqueue_reset_feed_fetches(enqueue_feeds?, feeds, enqueue_fun) do
      {:ok, Map.merge(delete_stats, enqueue_stats)}
    end
  end

  def feed_enqueue_unique_opts do
    [
      fields: [:worker, :args],
      period: enqueue_dedupe_seconds(),
      states: [:available, :scheduled, :executing, :retryable, :completed]
    ]
  end

  defp delete_article_and_source_rows do
    Repo.transaction(fn ->
      {deleted_article_sources, _} = Repo.delete_all(ArticleSource)
      {deleted_articles, _} = Repo.delete_all(PermanentArticle)
      {deleted_raw_sources, _} = Repo.delete_all(RawSource)

      %{
        deleted_article_sources: deleted_article_sources,
        deleted_articles: deleted_articles,
        deleted_raw_sources: deleted_raw_sources
      }
    end)
  end

  defp enqueue_reset_feed_fetches(false, _feeds, _enqueue_fun) do
    {:ok, %{enqueued_feed_jobs: 0, failed_feed_jobs: 0}}
  end

  defp enqueue_reset_feed_fetches(true, feeds, enqueue_fun) do
    {enqueued_feed_jobs, failed_feed_jobs} =
      feeds
      |> Enum.map(enqueue_fun)
      |> Enum.reduce({0, 0}, fn
        {:ok, _job}, {ok_count, error_count} -> {ok_count + 1, error_count}
        _other, {ok_count, error_count} -> {ok_count, error_count + 1}
      end)

    {:ok,
     %{
       enqueued_feed_jobs: enqueued_feed_jobs,
       failed_feed_jobs: failed_feed_jobs
     }}
  end

  defp enqueue_feed_fetch_for_reset(attrs), do: enqueue_feed_fetch(attrs, force: true)

  defp maybe_feed_unique_opts(opts) do
    if Keyword.get(opts, :force, false), do: false, else: feed_enqueue_unique_opts()
  end

  def alert_on_stale_feeds(opts \\ []) do
    started_at = System.monotonic_time()
    report = feed_freshness_report(opts)

    stale_providers =
      report
      |> Enum.filter(& &1.stale)
      |> Enum.map(& &1.origin_provider)

    metadata = %{
      result: :ok,
      stale_count: length(stale_providers),
      stale_providers: stale_providers
    }

    :telemetry.execute(
      [:leythers_com, :ingestion, :feed_stale_alert, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      metadata
    )

    %{stale_providers: stale_providers, report: report}
  end

  def refresh_stale_feeds(opts \\ []) do
    started_at = System.monotonic_time()
    alert = alert_on_stale_feeds(opts)
    stale_providers = alert.stale_providers
    enqueue_fun = opts[:enqueue_fun] || (&enqueue_feed_fetch/1)

    feeds_to_refresh =
      opts[:feeds] || configured_feeds()

    stale_provider_set = MapSet.new(stale_providers)

    stale_feeds =
      Enum.filter(feeds_to_refresh, fn feed ->
        provider = Map.get(feed, :origin_provider) || Map.get(feed, "origin_provider")
        MapSet.member?(stale_provider_set, provider)
      end)

    recovery_stats =
      Enum.reduce(stale_feeds, %{attempted: 0, enqueued: 0, failed: 0}, fn feed, acc ->
        case enqueue_fun.(feed) do
          {:ok, _job} ->
            %{acc | attempted: acc.attempted + 1, enqueued: acc.enqueued + 1}

          _ ->
            %{acc | attempted: acc.attempted + 1, failed: acc.failed + 1}
        end
      end)

    result =
      if recovery_stats.failed == 0 do
        :ok
      else
        :partial
      end

    :telemetry.execute(
      [:leythers_com, :ingestion, :feed_stale_recovery, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{
        result: result,
        stale_count: length(stale_providers),
        attempted: recovery_stats.attempted,
        enqueued: recovery_stats.enqueued,
        failed: recovery_stats.failed
      }
    )

    Map.merge(alert, recovery_stats)
  end

  def feed_freshness_report(opts \\ []) do
    started_at = System.monotonic_time()
    origin_providers = opts[:origin_providers] || configured_origin_providers()
    stale_after_hours = opts[:stale_after_hours] || stale_after_hours()

    latest_by_provider = latest_source_inserted_at_by_provider(origin_providers)
    now = DateTime.utc_now()
    stale_after_seconds = stale_after_hours * 3600

    report =
      Enum.map(origin_providers, fn origin_provider ->
        last_seen_at = Map.get(latest_by_provider, origin_provider)

        age_seconds =
          case last_seen_at do
            %DateTime{} = timestamp -> DateTime.diff(now, timestamp, :second)
            _ -> nil
          end

        stale = is_nil(age_seconds) or age_seconds > stale_after_seconds

        %{
          origin_provider: origin_provider,
          last_seen_at: last_seen_at,
          age_seconds: age_seconds,
          stale: stale
        }
      end)

    :telemetry.execute(
      [:leythers_com, :ingestion, :feed_freshness, :query, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{result: :ok, provider_count: length(origin_providers)}
    )

    report
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [r], r.status == ^status)

  defp blank?(value), do: value in [nil, ""]

  defp configured_origin_providers do
    configured_feeds()
    |> Enum.map(&(Map.get(&1, :origin_provider) || Map.get(&1, "origin_provider")))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp configured_feeds do
    Application.get_env(:leythers_com, :ingestion_feeds, [])
  end

  defp stale_after_hours do
    :leythers_com
    |> Application.get_env(:ingestion_monitoring, [])
    |> Keyword.get(:stale_after_hours, 6)
  end

  defp enqueue_dedupe_seconds do
    :leythers_com
    |> Application.get_env(:ingestion_monitoring, [])
    |> Keyword.get(:enqueue_dedupe_seconds, 900)
  end

  defp latest_source_inserted_at_by_provider([]), do: %{}

  defp latest_source_inserted_at_by_provider(origin_providers) do
    from(source in RawSource,
      where: source.origin_provider in ^origin_providers,
      group_by: source.origin_provider,
      select: {source.origin_provider, max(source.inserted_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp maybe_enqueue_editorial_generation({:ok, %{processed: processed}}) when processed > 0 do
    if auto_generation_enabled?() do
      _ = SourceEditorialWorker.enqueue()
    end

    :ok
  end

  defp maybe_enqueue_editorial_generation(_result), do: :ok

  defp auto_generation_enabled? do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:auto_generation_enabled, true)
  end

  defp ingest_feed_items(feed_url, origin_provider, include_keywords, http_client) do
    with {:ok, feed_body} <- http_client.fetch(feed_url) do
      stats =
        feed_body
        |> Rss.parse_items(origin_provider, feed_url)
        |> maybe_filter_items_by_keywords(include_keywords)
        |> reduce_feed_items()

      # Spawn background task to fetch article content for newly discovered sources
      spawn_content_fetcher(stats.new_source_ids)

      {:ok, stats}
    end
  end

  defp spawn_content_fetcher([_first | _rest] = source_ids) do
    Task.start_link(fn ->
      Enum.each(source_ids, &fetch_and_store_content/1)
    end)
  end

  defp spawn_content_fetcher(_source_ids), do: :ok

  defp fetch_and_store_content(source_id) do
    case Repo.get(RawSource, source_id) do
      nil ->
        :ok

      source ->
        case ArticleContentFetcher.fetch_and_extract(source.url) do
          {:ok, content} ->
            source
            |> RawSource.changeset(%{content: content})
            |> Repo.update()

          {:error, _reason} ->
            # Log but don't fail - body_summary is sufficient fallback
            :ok
        end
    end
  rescue
    _ -> :ok
  end

  defp emit_feed_ingestion_telemetry(result, started_at, origin_provider, feed_url) do
    metadata =
      case result do
        {:ok, stats} ->
          %{
            result: :ok,
            origin_provider: origin_provider,
            feed_url: feed_url,
            processed: stats.processed,
            inserted: stats.inserted,
            errors: stats.errors
          }

        {:error, reason} ->
          %{
            result: :error,
            origin_provider: origin_provider,
            feed_url: feed_url,
            reason: inspect(reason),
            processed: 0,
            inserted: 0,
            errors: 0
          }
      end

    :telemetry.execute(
      [:leythers_com, :ingestion, :feed_ingest, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      metadata
    )
  end

  defp maybe_filter_items_by_keywords(items, include_keywords) when is_list(include_keywords) do
    normalized_keywords =
      include_keywords
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)

    if normalized_keywords == [] do
      items
    else
      Enum.filter(items, &item_matches_keywords?(&1, normalized_keywords))
    end
  end

  defp maybe_filter_items_by_keywords(items, _include_keywords), do: items

  defp item_matches_keywords?(item, keywords) when is_map(item) do
    searchable_text =
      [Map.get(item, "title"), Map.get(item, "body_summary")]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(keywords, &String.contains?(searchable_text, &1))
  end

  defp item_matches_keywords?(_item, _keywords), do: false

  defp reduce_feed_items(items) do
    Enum.reduce(
      items,
      %{processed: 0, inserted: 0, errors: 0, items: [], new_source_ids: []},
      &accumulate_feed_item/2
    )
  end

  defp maybe_filter_regeneration_scope(query, :all, _now), do: query

  defp maybe_filter_regeneration_scope(query, :recent, now) do
    threshold = DateTime.add(now, -@recent_regeneration_window_days * 24 * 3600, :second)

    where(query, [source], source.external_published_at >= ^threshold)
  end

  defp maybe_enqueue_source_editorial_worker(requeued_sources, scope, false) do
    %{requeued_sources: requeued_sources, job_id: nil, scope: scope}
  end

  defp maybe_enqueue_source_editorial_worker(requeued_sources, scope, true) do
    case SourceEditorialWorker.enqueue(%{"drain_backlog" => true}) do
      {:ok, job} ->
        %{requeued_sources: requeued_sources, job_id: job.id, scope: scope}

      {:error, _reason} ->
        %{requeued_sources: requeued_sources, job_id: nil, scope: scope}
    end
  end

  defp regeneration_enqueue_worker? do
    Application.get_env(:leythers_com, :regeneration_enqueue_worker, true)
  end

  defp accumulate_feed_item(item, acc) do
    title = Map.get(item, "title")
    url = Map.get(item, "url")

    {status, source_id} = upsert_raw_source_tracked(item)

    item_detail = %{
      "title" => title,
      "url" => url,
      "status" => to_string(status)
    }

    new_ids = if status == :new and not is_nil(source_id), do: [source_id], else: []

    %{
      processed: acc.processed + 1,
      inserted: acc.inserted + if(status == :new, do: 1, else: 0),
      errors: acc.errors + if(status == :error, do: 1, else: 0),
      items: acc.items ++ [item_detail],
      new_source_ids: acc.new_source_ids ++ new_ids
    }
  end

  defp upsert_raw_source_tracked(attrs) do
    normalized = Basic.normalize(attrs)
    url = Map.get(normalized, :url) || Map.get(normalized, "url")
    changeset = RawSource.changeset(%RawSource{}, normalized)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :url) do
      {:ok, %{id: nil}} ->
        source = Repo.get_by!(RawSource, url: url)
        {:seen, source.id}

      {:ok, inserted} when not is_nil(inserted.id) ->
        _ = EditorialOrchestrator.trigger_source_update_refresh()
        {:new, inserted.id}

      {:ok, _} ->
        source = Repo.get_by(RawSource, url: url)
        {:seen, source && source.id}

      {:error, _changeset} ->
        {:error, nil}
    end
  end
end
