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
  alias LeythersCom.Intelligence.EditorialOrchestrator
  alias LeythersCom.Intelligence.LLMClient
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
        {:ok, _action, _article} ->
          mark_sources_processed(source_ids)
          _ = EditorialOrchestrator.trigger_source_update_refresh()

          :ok

        _ ->
          :ok
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
    rumour? = rumour_cluster?(cluster_sources)

    case llm_draft_attrs(cluster_sources, rumour?) do
      {:ok, llm_attrs} ->
        llm_attrs

      :error ->
        %{
          title: primary.title,
          body: summary
        }
    end
  end

  defp llm_draft_attrs(cluster_sources, rumour?) do
    if llm_draft_enabled?() do
      llm_draft_attrs_enabled(cluster_sources, rumour?)
    else
      :error
    end
  end

  defp llm_draft_attrs_enabled(cluster_sources, rumour?) do
    prompt = llm_prompt(cluster_sources, rumour?)

    case LLMClient.generate(prompt) do
      {:ok, %{text: text}} -> parse_and_record_draft(prompt, text)
      _ -> :error
    end
  end

  defp parse_and_record_draft(prompt, text) do
    case parse_llm_draft(text) do
      {:ok, attrs} ->
        record_llm_cost(prompt, text)
        {:ok, attrs}

      _ ->
        :error
    end
  end

  defp parse_llm_draft(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    title_line = Enum.find(lines, &String.starts_with?(String.upcase(&1), "TITLE:"))
    body_index = Enum.find_index(lines, &String.starts_with?(String.upcase(&1), "BODY:"))

    title =
      case title_line do
        nil -> List.first(lines)
        line -> String.trim_leading(line, "TITLE:") |> String.trim()
      end

    body =
      if is_integer(body_index) and body_index + 1 < length(lines) do
        lines
        |> Enum.drop(body_index + 1)
        |> Enum.join("\n")
      else
        lines
        |> Enum.drop(1)
        |> Enum.join("\n")
      end

    if blank?(title) or blank?(body) do
      :error
    else
      {:ok, %{title: String.slice(title, 0, 180), body: String.slice(body, 0, 12_000)}}
    end
  end

  defp parse_llm_draft(_), do: :error

  defp llm_prompt(cluster_sources, rumour?) do
    """
    Write a concise Leythers-style rugby article using these source notes.

    Requirements:
    - Keep factual grounding to provided notes only.
    - Return plain text with this exact format:
      TITLE: <single title line>
      BODY:
      <markdown body, 2-4 short paragraphs>
    - If rumour is true, use cautious language and include uncertainty.

    Rumour: #{rumour?}

    Source notes:
    #{article_summary(cluster_sources)}
    """
  end

  defp record_llm_cost(prompt, completion) do
    prompt_tokens = estimate_tokens(prompt)
    output_tokens = estimate_tokens(completion)
    total_tokens = prompt_tokens + output_tokens

    estimated_cost_gbp =
      llm_cost_per_1k_tokens_gbp()
      |> Decimal.mult(Decimal.new(total_tokens))
      |> Decimal.div(Decimal.new(1000))

    _ =
      Intelligence.upsert_cost_ledger(%{
        date: Date.utc_today(),
        input_tokens: prompt_tokens,
        output_tokens: output_tokens,
        estimated_cost_gbp: estimated_cost_gbp
      })

    :ok
  end

  defp estimate_tokens(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
    |> max(1)
  end

  defp estimate_tokens(_), do: 1

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

  defp llm_draft_enabled? do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:llm_draft_enabled, true)
  end

  defp llm_cost_per_1k_tokens_gbp do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:llm_cost_per_1k_tokens_gbp, "0.000000")
    |> Decimal.new()
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

  defp blank?(value), do: value in [nil, ""]
end
