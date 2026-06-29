defmodule LeythersCom.Intelligence.SourceEditorialWorker do
  @moduledoc """
  Promotes pending raw sources into AI editorial updates.

  The worker clusters recently ingested pending sources into lightweight story
  groups, publishes/updates AI articles for each cluster, and marks sources as
  processed after successful publication.
  """

  use Oban.Worker, queue: :intelligence, max_attempts: 3

  import Ecto.Query

  alias LeythersCom.Content
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Intelligence
  alias LeythersCom.Repo

  @default_batch_size 20

  def enqueue(attrs \\ %{}) when is_map(attrs) do
    attrs
    |> normalize_args()
    |> new(unique: [fields: [:worker], period: 60, states: [:available, :scheduled, :executing]])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if auto_generation_enabled?() do
      process_pending_sources(args)
    else
      :ok
    end
  end

  defp process_pending_sources(args) do
    source_limit = Map.get(args, "source_limit", default_batch_size())

    pending_sources =
      RawSource
      |> where([source], source.status == "pending")
      |> order_by([source], asc: source.external_published_at, asc: source.inserted_at)
      |> limit(^source_limit)
      |> Repo.all()

    pending_sources
    |> cluster_sources()
    |> Enum.each(&publish_cluster/1)

    :ok
  end

  defp publish_cluster([]), do: :ok

  defp publish_cluster(cluster_sources) do
    if Intelligence.ensure_generation_allowed!(Date.utc_today()) == :ok do
      attrs = build_article_attrs(cluster_sources)
      source_ids = Enum.map(cluster_sources, & &1.id)

      case Content.publish_or_update_ai_article(attrs, source_ids,
             rumour: rumour_cluster?(cluster_sources),
             significant_change: significant_change_cluster?(cluster_sources)
           ) do
        {:ok, _action, _article} -> mark_sources_processed(source_ids)
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp mark_sources_processed([]), do: :ok

  defp mark_sources_processed(source_ids) do
    from(source in RawSource, where: source.id in ^source_ids)
    |> Repo.update_all(set: [status: "processed"])

    :ok
  end

  defp build_article_attrs(cluster_sources) do
    primary = List.first(cluster_sources)
    summary = article_summary(cluster_sources)

    %{
      title: primary.title,
      body: summary
    }
  end

  defp article_summary(cluster_sources) do
    cluster_sources
    |> Enum.map_join("\n", fn source ->
      summary = source.body_summary || "No summary available from source feed."
      "- #{source.origin_provider}: #{summary}"
    end)
    |> then(&"Automated feed digest:\n\n#{&1}")
  end

  defp rumour_cluster?(cluster_sources) do
    cluster_sources
    |> Enum.map(&String.downcase(&1.title || ""))
    |> Enum.any?(fn title ->
      String.contains?(title, "rumour") or String.contains?(title, "linked") or
        String.contains?(title, "interest")
    end)
  end

  defp significant_change_cluster?(cluster_sources), do: length(cluster_sources) >= 3

  defp cluster_sources(sources) do
    sources
    |> Enum.group_by(&story_key(&1.title))
    |> Map.values()
  end

  defp story_key(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(5)
    |> Enum.join(" ")
  end

  defp story_key(_), do: ""

  defp auto_generation_enabled? do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:auto_generation_enabled, true)
  end

  defp default_batch_size do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:source_batch_size, @default_batch_size)
  end

  defp normalize_args(args) do
    args
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end
end
