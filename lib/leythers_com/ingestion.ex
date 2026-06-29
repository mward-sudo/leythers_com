defmodule LeythersCom.Ingestion do
  @moduledoc """
  Ingestion context for creating and querying normalized raw sources.
  """

  import Ecto.Query

  alias LeythersCom.Ingestion.FetchRssFeedWorker
  alias LeythersCom.Ingestion.HttpClient.Req
  alias LeythersCom.Ingestion.Providers.Basic
  alias LeythersCom.Ingestion.Providers.Rss
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Intelligence.EditorialOrchestrator
  alias LeythersCom.Repo

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
    attrs = Basic.normalize(attrs)
    feed_url = Map.get(attrs, "url")
    origin_provider = Map.get(attrs, "origin_provider")
    include_keywords = Map.get(attrs, "include_keywords", [])

    cond do
      blank?(feed_url) ->
        {:error, :missing_url}

      blank?(origin_provider) ->
        {:error, :missing_origin_provider}

      true ->
        ingest_feed_items(feed_url, origin_provider, include_keywords, http_client)
    end
  end

  def ingest_configured_feeds do
    :leythers_com
    |> Application.get_env(:ingestion_feeds, [])
    |> Enum.map(&enqueue_feed_fetch/1)
  end

  def enqueue_feed_fetch(attrs) when is_map(attrs) do
    attrs
    |> Basic.normalize()
    |> FetchRssFeedWorker.new()
    |> Oban.insert()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [r], r.status == ^status)

  defp blank?(value), do: value in [nil, ""]

  defp ingest_feed_items(feed_url, origin_provider, include_keywords, http_client) do
    with {:ok, feed_body} <- http_client.fetch(feed_url) do
      feed_body
      |> Rss.parse_items(origin_provider, feed_url)
      |> maybe_filter_items_by_keywords(include_keywords)
      |> reduce_feed_items()
      |> then(&{:ok, &1})
    end
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
    Enum.reduce(items, %{processed: 0, inserted: 0, errors: 0}, &accumulate_feed_item/2)
  end

  defp accumulate_feed_item(item, acc) do
    case upsert_raw_source(item) do
      {:ok, source} ->
        inserted = if source.inserted_at == source.updated_at, do: 1, else: 0
        %{acc | processed: acc.processed + 1, inserted: acc.inserted + inserted}

      {:error, _changeset} ->
        %{acc | processed: acc.processed + 1, errors: acc.errors + 1}
    end
  end
end
