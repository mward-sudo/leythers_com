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
  @default_max_batches_per_run 20
  @default_significance_threshold 70
  @default_prompt_version "source_editorial_v1"

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
    max_batches = Map.get(args, "max_batches", max_batches_per_run())
    drain_backlog? = Map.get(args, "drain_backlog", true)
    run_id = Ecto.UUID.generate()

    process_batches(run_id, source_limit, max_batches, drain_backlog?)

    :ok
  end

  defp process_batches(_run_id, _source_limit, max_batches, _drain_backlog?)
       when max_batches <= 0,
       do: :ok

  defp process_batches(run_id, source_limit, max_batches, drain_backlog?) do
    pending_sources = fetch_pending_sources(source_limit)

    case pending_sources do
      [] ->
        :ok

      _ ->
        {processed_count, budget_blocked?} = process_batch(pending_sources, run_id)

        cond do
          budget_blocked? ->
            :ok

          not drain_backlog? ->
            :ok

          processed_count <= 0 ->
            :ok

          true ->
            process_batches(run_id, source_limit, max_batches - 1, true)
        end
    end
  end

  defp fetch_pending_sources(source_limit) do
    RawSource
    |> where([source], source.status == "pending")
    |> order_by([source], asc: source.external_published_at, asc: source.inserted_at)
    |> limit(^source_limit)
    |> Repo.all()
  end

  defp process_batch(pending_sources, run_id) do
    pending_sources
    |> cluster_sources()
    |> Enum.reduce_while({0, false}, fn cluster_sources, {processed_total, _} ->
      case publish_cluster(cluster_sources, run_id) do
        {:ok, processed_count} ->
          {:cont, {processed_total + processed_count, false}}

        {:halt, :budget_blocked} ->
          {:halt, {processed_total, true}}
      end
    end)
  end

  defp publish_cluster([], _run_id), do: {:ok, 0}

  defp publish_cluster(cluster_sources, run_id) do
    source_ids = Enum.map(cluster_sources, & &1.id)
    significance_score = significance_score(cluster_sources)
    threshold = significance_threshold()
    rumour? = rumour_cluster?(cluster_sources)

    decision_attrs = %{
      run_id: run_id,
      source_ids: source_ids,
      source_count: length(source_ids),
      significance_score: significance_score,
      significance_threshold: threshold,
      prompt_version: prompt_version()
    }

    if Intelligence.ensure_generation_allowed!(Date.utc_today()) == :ok do
      {attrs, llm_cost_attrs} = build_article_attrs(cluster_sources)

      case Content.publish_or_update_ai_article(attrs, source_ids,
             rumour: rumour?,
             significant_change: significance_score >= threshold
           ) do
        {:ok, action, article} ->
          processed_count = mark_sources_processed(source_ids)
          _ = EditorialOrchestrator.trigger_source_update_refresh()

          persist_decision(
            decision_attrs,
            to_string(action),
            article.id,
            decision_summary(significance_score, threshold, source_ids, rumour?, llm_cost_attrs),
            llm_cost_attrs
          )

          {:ok, processed_count}

        _ ->
          persist_decision(
            decision_attrs,
            "skipped_publish_error",
            nil,
            decision_summary(significance_score, threshold, source_ids, rumour?, llm_cost_attrs),
            llm_cost_attrs
          )

          {:ok, 0}
      end
    else
      persist_decision(
        decision_attrs,
        "skipped_budget",
        nil,
        decision_summary(significance_score, threshold, source_ids, rumour?, zero_cost_attrs()),
        zero_cost_attrs()
      )

      {:halt, :budget_blocked}
    end
  end

  defp mark_sources_processed([]), do: 0

  defp mark_sources_processed(source_ids) do
    from(source in RawSource, where: source.id in ^source_ids)
    |> Repo.update_all(set: [status: "processed"])
    |> elem(0)
  end

  defp build_article_attrs(cluster_sources) do
    primary = List.first(cluster_sources)
    summary = article_summary(cluster_sources)
    rumour? = rumour_cluster?(cluster_sources)

    case llm_draft_attrs(cluster_sources, rumour?) do
      {:ok, llm_attrs, llm_cost_attrs} ->
        {llm_attrs, llm_cost_attrs}

      :error ->
        {
          %{
            title: primary.title,
            body: summary
          },
          zero_cost_attrs()
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
        llm_cost_attrs = record_llm_cost(prompt, text)
        {:ok, attrs, llm_cost_attrs}

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

    %{
      input_tokens: prompt_tokens,
      output_tokens: output_tokens,
      estimated_cost_gbp: estimated_cost_gbp
    }
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

  defp significance_score(cluster_sources) do
    source_count_score = min(length(cluster_sources) * 25, 60)
    provider_diversity_score = min(distinct_provider_count(cluster_sources) * 15, 30)
    rumour_score = if rumour_cluster?(cluster_sources), do: 10, else: 0

    source_count_score + provider_diversity_score + rumour_score
  end

  defp distinct_provider_count(cluster_sources) do
    cluster_sources
    |> Enum.map(& &1.origin_provider)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> length()
  end

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

  defp max_batches_per_run do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:max_batches_per_run, @default_max_batches_per_run)
  end

  defp significance_threshold do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:significance_threshold, @default_significance_threshold)
  end

  defp prompt_version do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:prompt_version, @default_prompt_version)
  end

  defp persist_decision(base_attrs, action, article_id, summary, llm_cost_attrs) do
    attrs =
      base_attrs
      |> Map.merge(llm_cost_attrs)
      |> Map.put(:decision_action, action)
      |> Map.put(:decision_summary, summary)
      |> Map.put(:permanent_article_id, article_id)

    _ = Intelligence.create_article_generation_decision(attrs)
    :ok
  end

  defp decision_summary(significance_score, threshold, source_ids, rumour?, llm_cost_attrs) do
    llm_mode = if llm_cost_attrs.input_tokens > 0, do: "llm_draft", else: "deterministic"

    "significance #{significance_score}/#{threshold}; sources #{length(source_ids)}; rumour #{rumour?}; mode #{llm_mode}"
  end

  defp zero_cost_attrs do
    %{input_tokens: 0, output_tokens: 0, estimated_cost_gbp: Decimal.new("0")}
  end

  defp normalize_args(args) do
    args
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp blank?(value), do: value in [nil, ""]
end
