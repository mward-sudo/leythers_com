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
  alias LeythersCom.Intelligence.SourceClusterer
  alias LeythersCom.Repo

  @default_batch_size 20
  @default_max_batches_per_run 20
  @default_significance_threshold 70
  @default_prompt_version "source_editorial_v1"
  @default_enqueue_unique_seconds 3_600
  @default_worker_timeout_ms :timer.minutes(10)

  def enqueue(attrs \\ %{}) when is_map(attrs) do
    attrs
    |> normalize_args()
    |> new(
      unique: [
        fields: [:worker],
        period: enqueue_unique_seconds(),
        states: [:available, :scheduled, :executing]
      ]
    )
    |> Oban.insert()
  end

  @impl Oban.Worker
  def timeout(%Oban.Job{} = _job), do: worker_timeout_ms()

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if auto_generation_enabled?() do
      process_pending_sources(job)
    else
      :ok
    end
  end

  defp process_pending_sources(%Oban.Job{args: args} = job) do
    source_limit = Map.get(args, "source_limit", default_batch_size())
    max_batches = Map.get(args, "max_batches", max_batches_per_run())
    drain_backlog? = Map.get(args, "drain_backlog", true)
    run_id = Ecto.UUID.generate()

    process_batches(job, run_id, source_limit, max_batches, drain_backlog?)
  end

  defp process_batches(_job, _run_id, _source_limit, max_batches, _drain_backlog?)
       when max_batches <= 0,
       do: :ok

  defp process_batches(job, run_id, source_limit, max_batches, drain_backlog?) do
    pending_sources = fetch_pending_sources(source_limit)

    case pending_sources do
      [] ->
        :ok

      _ ->
        case process_batch(job, pending_sources, run_id) do
          {:ok, processed_count, budget_blocked?} ->
            cond do
              budget_blocked? ->
                :ok

              not drain_backlog? ->
                :ok

              processed_count <= 0 ->
                :ok

              true ->
                process_batches(job, run_id, source_limit, max_batches - 1, true)
            end

          {:error, reason} ->
            {:error, reason}
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

  defp process_batch(job, pending_sources, run_id) do
    pending_sources
    |> cluster_sources()
    |> Enum.reduce_while({:ok, 0, false}, fn cluster_sources, {:ok, processed_total, _} ->
      case publish_cluster(job, cluster_sources, run_id) do
        {:ok, processed_count} ->
          {:cont, {:ok, processed_total + processed_count, false}}

        {:halt, :budget_blocked} ->
          {:halt, {:ok, processed_total, true}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp publish_cluster(_job, [], _run_id), do: {:ok, 0}

  defp publish_cluster(job, cluster_sources, run_id) do
    source_ids = Enum.map(cluster_sources, & &1.id)
    significance_score = significance_score(cluster_sources)
    threshold = significance_threshold()
    rumour? = rumour_cluster?(cluster_sources)
    cluster_snapshot = source_snapshot(cluster_sources)

    decision_attrs = %{
      run_id: run_id,
      source_ids: source_ids,
      source_count: length(source_ids),
      significance_score: significance_score,
      significance_threshold: threshold,
      prompt_version: prompt_version()
    }

    if Intelligence.ensure_generation_allowed!(Date.utc_today()) == :ok do
      with {:ok, attrs, llm_cost_attrs} <- build_article_attrs(cluster_sources) do
        case Content.publish_or_update_ai_article(attrs, source_ids,
               rumour: rumour?,
               significant_change: significance_score >= threshold
             ) do
          {:ok, action, article} ->
            processed_count = mark_sources_processed(source_ids)
            _ = EditorialOrchestrator.trigger_source_update_refresh()

            action_str = to_string(action)

            summary =
              decision_summary(significance_score, threshold, source_ids, rumour?, llm_cost_attrs)

            persist_decision(
              decision_attrs,
              action_str,
              article.id,
              summary,
              llm_cost_attrs
            )

            persist_job_effect_event(job, %{
              decision_action: action_str,
              permanent_article_id: article.id,
              process_run_id: run_id,
              source_ids: source_ids,
              source_input_snapshot: cluster_snapshot,
              change_summary: summary,
              change_details: %{
                significance_score: significance_score,
                significance_threshold: threshold,
                source_count: length(source_ids),
                run_id: run_id,
                prompt_version: prompt_version(),
                llm_cost: llm_cost_attrs,
                rumour: rumour?
              },
              error_summary: nil
            })

            {:ok, processed_count}

          {:error, reason} ->
            summary =
              decision_summary(significance_score, threshold, source_ids, rumour?, llm_cost_attrs)

            persist_decision(
              decision_attrs,
              "skipped_publish_error",
              nil,
              summary,
              llm_cost_attrs
            )

            persist_job_effect_event(job, %{
              decision_action: "skipped_publish_error",
              permanent_article_id: nil,
              process_run_id: run_id,
              source_ids: source_ids,
              source_input_snapshot: cluster_snapshot,
              change_summary: summary,
              change_details: %{
                significance_score: significance_score,
                significance_threshold: threshold,
                source_count: length(source_ids),
                run_id: run_id,
                prompt_version: prompt_version(),
                llm_cost: llm_cost_attrs,
                rumour: rumour?
              },
              error_summary: inspect(reason)
            })

            # Mark sources as processed to avoid infinite loop on validation errors
            mark_sources_processed(source_ids)

            {:ok, 0}
        end
      else
        {:error, reason} ->
          {:error, {:llm_unavailable, reason}}
      end
    else
      summary =
        decision_summary(significance_score, threshold, source_ids, rumour?, zero_cost_attrs())

      persist_decision(
        decision_attrs,
        "skipped_budget",
        nil,
        summary,
        zero_cost_attrs()
      )

      persist_job_effect_event(job, %{
        decision_action: "skipped_budget",
        permanent_article_id: nil,
        process_run_id: run_id,
        source_ids: source_ids,
        source_input_snapshot: cluster_snapshot,
        change_summary: summary,
        change_details: %{
          significance_score: significance_score,
          significance_threshold: threshold,
          source_count: length(source_ids),
          run_id: run_id,
          prompt_version: prompt_version(),
          llm_cost: zero_cost_attrs(),
          rumour: rumour?
        },
        error_summary: nil
      })

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
    summary_fallback = article_summary(cluster_sources)
    rumour? = rumour_cluster?(cluster_sources)

    if llm_draft_enabled?() do
      llm_draft_attrs(cluster_sources, rumour?)
    else
      {:ok,
       %{
         headline: primary.title,
         summary: summary_fallback,
         body: summary_fallback
       }, zero_cost_attrs()}
    end
  end

  defp llm_draft_attrs(cluster_sources, rumour?) do
    prompt = llm_prompt(cluster_sources, rumour?)

    case LLMClient.generate(prompt) do
      {:ok, %{text: text}} -> parse_and_record_draft(prompt, text)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_and_record_draft(prompt, text) do
    case parse_llm_draft(text) do
      {:ok, attrs} ->
        llm_cost_attrs = record_llm_cost(prompt, text)
        {:ok, attrs, llm_cost_attrs}

      _ ->
        {:error, :invalid_llm_draft_response}
    end
  end

  defp parse_llm_draft(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {headline, summary, body} = extract_draft_parts(lines)

    sanitized_headline = sanitize_plain_text(headline)
    sanitized_summary = sanitize_plain_text(summary)
    sanitized_body = sanitize_plain_text(body)

    if blank?(sanitized_headline) or blank?(sanitized_summary) or blank?(sanitized_body) do
      :error
    else
      {:ok,
       %{
         headline: String.slice(sanitized_headline, 0, 100),
         summary: String.slice(sanitized_summary, 0, 280),
         body: String.slice(sanitized_body, 0, 12_000)
       }}
    end
  end

  defp parse_llm_draft(_), do: :error

  defp extract_draft_parts(lines) do
    headline_line = Enum.find(lines, &String.starts_with?(String.upcase(&1), "HEADLINE:"))
    summary_line = Enum.find(lines, &String.starts_with?(String.upcase(&1), "SUMMARY:"))
    body_index = Enum.find_index(lines, &String.starts_with?(String.upcase(&1), "BODY:"))

    headline =
      case headline_line do
        nil -> ""
        line -> extract_after_prefix(line, "HEADLINE:")
      end

    summary =
      case summary_line do
        nil -> ""
        line -> extract_after_prefix(line, "SUMMARY:")
      end

    body =
      if is_integer(body_index) and body_index + 1 < length(lines) do
        lines
        |> Enum.drop(body_index + 1)
        |> Enum.join("\n")
      else
        ""
      end

    {headline, summary, body}
  end

  defp extract_after_prefix(line, prefix) do
    case String.split_at(line, String.length(prefix)) do
      {^prefix, rest} -> String.trim(rest)
      _ -> String.trim(line)
    end
  end

  defp llm_prompt(cluster_sources, rumour?) do
    """
    Write a Leythers-style rugby article in three parts using these source notes.

    Voice guidance:
    - Fan-journalist tone: colloquial Leigh perspective, light humour, terrace vernacular
    - Be factual and grounded in provided notes only
    - #{if rumour?, do: "Use cautious language for rumours; mark uncertainty clearly", else: "Be direct and confident in factual reporting"}
    - Headlines lead with Leigh angle, avoid clickbait and major spoilers
    - Summaries are plain-text teasers that encourage reading the full piece

    Return exactly this format:
    HEADLINE: <compelling Leigh-focused headline, max 100 chars>
    SUMMARY: <plain-text teaser, max 280 chars, no HTML or markdown>
    BODY:
    <full article in 3-5 paragraphs, markdown-safe, with Leythers voice>

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
      # Prefer full content if available; fall back to body_summary
      raw_text = source.content || source.body_summary || ""
      summary = raw_text |> sanitize_plain_text() |> truncate_for_prompt(500)
      "- #{source.origin_provider}: #{summary}"
    end)
    |> then(&"Automated feed digest:\n\n#{&1}")
  end

  defp truncate_for_prompt(text, max_len) when is_binary(text) and is_integer(max_len) do
    if String.length(text) <= max_len do
      text
    else
      String.slice(text, 0, max_len) <> "..."
    end
  end

  defp sanitize_plain_text(summary) when is_binary(summary) do
    cleaned =
      summary
      |> String.replace("\u00A0", " ")
      |> strip_html()
      |> String.replace("\u00A0", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.replace(~r/\s+([,.;:!?])/, "\\1")
      |> String.trim()

    if cleaned == "" do
      "No summary available from source feed."
    else
      cleaned
    end
  end

  defp sanitize_plain_text(_), do: "No summary available from source feed."

  defp strip_html(text) do
    case Floki.parse_fragment(text) do
      {:ok, html_nodes} -> Floki.text(html_nodes, sep: " ")
      _error -> Regex.replace(~r/<[^>]*>/, text, " ")
    end
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
    # Use aggressive semantic clustering to group sources on the same topic
    # This prevents generating multiple articles for the same subject
    SourceClusterer.cluster_by_topic(sources)
  end

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

  defp enqueue_unique_seconds do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:source_editorial_enqueue_unique_seconds, @default_enqueue_unique_seconds)
  end

  defp worker_timeout_ms do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:source_editorial_worker_timeout_ms, @default_worker_timeout_ms)
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

  defp source_snapshot(cluster_sources) do
    %{
      "sources" =>
        Enum.map(cluster_sources, fn source ->
          %{
            "id" => source.id,
            "origin_provider" => source.origin_provider,
            "title" => source.title,
            "url" => source.url,
            "inserted_at" => format_dt(source.inserted_at),
            "external_published_at" => format_dt(source.external_published_at)
          }
        end)
    }
  end

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_dt(nil), do: nil

  defp json_safe(%Decimal{} = d), do: Decimal.to_string(d)
  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp json_safe(%Date{} = d), do: Date.to_iso8601(d)

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), json_safe(v)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value), do: value

  defp persist_job_effect_event(job, attrs) do
    oban_job_id = if is_integer(job.id), do: job.id, else: 0
    queue = if is_binary(job.queue), do: job.queue, else: "intelligence"

    worker =
      if is_binary(job.worker),
        do: job.worker,
        else: __MODULE__ |> Module.split() |> Enum.join(".")

    attempt = if is_integer(job.attempt), do: max(job.attempt, 1), else: 1

    _ =
      Intelligence.create_job_effect_event(%{
        oban_job_id: oban_job_id,
        worker: worker,
        queue: queue,
        state: "completed",
        attempt: attempt,
        decision_action: attrs.decision_action,
        permanent_article_id: attrs.permanent_article_id,
        process_run_id: attrs.process_run_id,
        source_ids: attrs.source_ids,
        source_input_snapshot: json_safe(attrs.source_input_snapshot),
        change_summary: attrs.change_summary,
        change_details: json_safe(attrs.change_details),
        error_summary: attrs.error_summary
      })

    :ok
  end

  defp blank?(value), do: value in [nil, ""]
end
