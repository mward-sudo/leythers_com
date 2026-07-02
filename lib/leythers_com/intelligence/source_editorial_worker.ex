defmodule LeythersCom.Intelligence.SourceEditorialWorker do
  @moduledoc """
  Promotes pending raw sources into AI editorial updates.

  The worker clusters recently ingested pending sources into lightweight story
  groups, publishes/updates AI articles for each cluster, and marks sources as
  processed after successful publication.
  """

  use Oban.Worker, queue: :intelligence, max_attempts: 25

  import Ecto.Query

  alias LeythersCom.Content
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Ingestion.RawSourceStatusMachine
  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.EditorialOrchestrator
  alias LeythersCom.Intelligence.LLMClient
  alias LeythersCom.Repo

  @default_batch_size 100
  @default_max_batches_per_run 100
  @default_significance_threshold 70
  @default_prompt_version "source_editorial_v1"
  @default_enqueue_unique_seconds 3_600
  @default_worker_timeout_ms 30_000
  @default_llm_draft_timeout_ms 7_500
  @default_dispatch_delay_ms 2_000
  @default_dispatch_delay_max_ms 15_000
  @default_retry_base_seconds 1
  @default_retry_max_seconds 15
  @default_retry_persist_threshold 3

  def enqueue(attrs \\ %{}) when is_map(attrs) do
    # Always use a canonical dispatch task key so that cluster tasks (which share
    # the same worker but carry different args) do not block new dispatch jobs
    # from being inserted via the uniqueness constraint.
    _ = attrs

    %{"task" => "dispatch"}
    |> new(
      unique: [
        fields: [:worker, :args],
        period: enqueue_unique_seconds(),
        # Keep only one canonical dispatch job active across available/scheduled/executing states.
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> Oban.insert()
  end

  @impl Oban.Worker
  def timeout(%Oban.Job{} = _job), do: worker_timeout_ms()

  @impl Oban.Worker
  def backoff(%Oban.Job{} = job) do
    base_seconds = retry_base_seconds() |> max(1)
    max_seconds = retry_max_seconds() |> max(base_seconds)
    attempt = max(job.attempt, 1)
    persist_threshold = retry_persist_threshold() |> max(1)

    delay_seconds =
      if attempt <= persist_threshold do
        base_seconds
      else
        escalation_attempt = attempt - persist_threshold
        base_seconds * trunc(:math.pow(2, escalation_attempt - 1))
      end

    min(delay_seconds, max_seconds)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if auto_generation_enabled?() do
      case Map.get(job.args, "task") do
        "cluster" -> process_cluster_task(job)
        _ -> process_pending_sources(job)
      end
    else
      :ok
    end
  end

  defp process_pending_sources(%Oban.Job{args: args} = job) do
    source_limit = Map.get(args, "source_limit", default_batch_size())
    max_batches = Map.get(args, "max_batches", max_batches_per_run())
    drain_backlog? = Map.get(args, "drain_backlog", true)
    run_id = Ecto.UUID.generate()

    dispatch_cluster_tasks(job, run_id, source_limit, max_batches, drain_backlog?)
  end

  defp dispatch_cluster_tasks(_job, _run_id, _source_limit, max_batches, _drain_backlog?)
       when max_batches <= 0,
       do: :ok

  defp dispatch_cluster_tasks(job, run_id, source_limit, max_batches, drain_backlog?) do
    pending_sources = fetch_pending_sources(source_limit)

    case pending_sources do
      [] ->
        :ok

      _ ->
        pending_sources
        |> enqueue_source_jobs(run_id)
        |> case do
          :ok ->
            maybe_enqueue_dispatch_continuation(
              job,
              pending_sources,
              source_limit,
              max_batches,
              drain_backlog?
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp enqueue_source_jobs(pending_sources, run_id) do
    pending_sources
    |> Enum.map(&[&1])
    |> Enum.reduce_while(:ok, fn cluster, :ok ->
      case build_cluster_job(cluster, run_id) |> Oban.insert() do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_cluster_job(cluster, run_id) do
    source_ids = Enum.map(cluster, & &1.id)

    %{"task" => "cluster", "process_run_id" => run_id, "source_ids" => source_ids}
    |> new(
      unique: [
        fields: [:worker, :args],
        period: enqueue_unique_seconds(),
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
  end

  defp fetch_pending_sources(source_limit) do
    RawSource
    |> where([source], source.status == "pending")
    |> order_by([source], asc: source.external_published_at, asc: source.inserted_at)
    |> limit(^source_limit)
    |> Repo.all()
  end

  defp maybe_enqueue_dispatch_continuation(
         _job,
         _pending_sources,
         _source_limit,
         _max_batches,
         false
       ),
       do: :ok

  defp maybe_enqueue_dispatch_continuation(
         _job,
         _pending_sources,
         _source_limit,
         max_batches,
         _drain_backlog?
       )
       when max_batches <= 1,
       do: :ok

  defp maybe_enqueue_dispatch_continuation(_job, pending_sources, source_limit, max_batches, true) do
    if length(pending_sources) < source_limit do
      :ok
    else
      _max_batches_left = max_batches - 1
      enqueue_dispatch_continuation()
    end
  end

  defp enqueue_dispatch_continuation do
    delay_seconds = div(dispatch_delay_ms(), 1_000) |> max(1)

    %{"task" => "dispatch"}
    |> new(
      schedule_in: delay_seconds,
      unique: [
        fields: [:worker, :args],
        period: enqueue_unique_seconds(),
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> Oban.insert()

    :ok
  end

  defp process_cluster_task(%Oban.Job{args: args} = job) do
    run_id = Map.get(args, "process_run_id", Ecto.UUID.generate())
    source_ids = Map.get(args, "source_ids", [])

    cluster_sources = fetch_sources_by_ids(source_ids)

    case cluster_sources do
      [] ->
        :ok

      _ ->
        case publish_cluster(job, cluster_sources, run_id) do
          {:ok, _processed_count} -> :ok
          {:halt, :budget_blocked} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp fetch_sources_by_ids(source_ids) when is_list(source_ids) do
    RawSource
    |> where([source], source.id in ^source_ids)
    |> where([source], source.status == "pending")
    |> order_by([source], asc: source.external_published_at, asc: source.inserted_at)
    |> Repo.all()
  end

  defp fetch_sources_by_ids(_source_ids), do: []

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
      case build_article_attrs(cluster_sources) do
        {:ok, attrs, llm_cost_attrs} ->
          publish_cluster_article(
            job,
            attrs,
            %{
              source_ids: source_ids,
              run_id: run_id,
              cluster_snapshot: cluster_snapshot,
              decision_attrs: decision_attrs,
              significance_score: significance_score,
              threshold: threshold,
              rumour?: rumour?,
              llm_cost_attrs: llm_cost_attrs
            }
          )

        {:error, :source_content_not_ready} ->
          handle_content_not_ready_cluster(
            job,
            source_ids,
            run_id,
            decision_attrs,
            cluster_snapshot
          )

        {:error, :no_relevant_sources} ->
          handle_irrelevant_cluster(job, source_ids, run_id, decision_attrs, cluster_snapshot)

        {:error, :invalid_llm_draft_response} ->
          handle_invalid_draft_cluster(job, source_ids, run_id, decision_attrs, cluster_snapshot)

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

  defp publish_cluster_article(
         job,
         attrs,
         %{
           source_ids: source_ids,
           run_id: run_id,
           cluster_snapshot: cluster_snapshot,
           decision_attrs: decision_attrs,
           significance_score: significance_score,
           threshold: threshold,
           rumour?: rumour?,
           llm_cost_attrs: llm_cost_attrs
         }
       ) do
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
  end

  defp mark_sources_processed([]), do: 0

  defp mark_sources_processed(source_ids) do
    source_ids
    |> fetch_sources_by_ids()
    |> Enum.reduce(0, fn source, acc ->
      case RawSourceStatusMachine.mark_processed(source) do
        {:ok, _updated_source} -> acc + 1
        _other -> acc
      end
    end)
  end

  defp mark_sources_ignored([]), do: 0

  defp mark_sources_ignored(source_ids) do
    source_ids
    |> fetch_sources_by_ids()
    |> Enum.reduce(0, fn source, acc ->
      case RawSourceStatusMachine.mark_ignored(source) do
        {:ok, _updated_source} -> acc + 1
        _other -> acc
      end
    end)
  end

  defp handle_irrelevant_cluster(job, source_ids, run_id, decision_attrs, cluster_snapshot) do
    summary =
      "sources #{length(source_ids)} skipped as irrelevant for draft (no relevant source content)"

    llm_cost_attrs = zero_cost_attrs()

    persist_decision(
      decision_attrs,
      "skipped_irrelevant",
      nil,
      summary,
      llm_cost_attrs
    )

    persist_job_effect_event(job, %{
      decision_action: "skipped_irrelevant",
      permanent_article_id: nil,
      process_run_id: run_id,
      source_ids: source_ids,
      source_input_snapshot: cluster_snapshot,
      change_summary: summary,
      change_details: %{
        source_count: length(source_ids),
        run_id: run_id,
        prompt_version: prompt_version(),
        llm_cost: llm_cost_attrs,
        reason: "no_relevant_sources"
      },
      error_summary: nil
    })

    ignored_count = mark_sources_ignored(source_ids)
    {:ok, ignored_count}
  end

  defp handle_content_not_ready_cluster(
         job,
         source_ids,
         run_id,
         decision_attrs,
         cluster_snapshot
       ) do
    summary =
      "sources #{length(source_ids)} waiting for full content before editorial draft"

    llm_cost_attrs = zero_cost_attrs()

    persist_decision(
      decision_attrs,
      "skipped_waiting_content",
      nil,
      summary,
      llm_cost_attrs
    )

    persist_job_effect_event(job, %{
      decision_action: "skipped_waiting_content",
      permanent_article_id: nil,
      process_run_id: run_id,
      source_ids: source_ids,
      source_input_snapshot: cluster_snapshot,
      change_summary: summary,
      change_details: %{
        source_count: length(source_ids),
        run_id: run_id,
        prompt_version: prompt_version(),
        llm_cost: llm_cost_attrs,
        reason: "source_content_not_ready"
      },
      error_summary: nil
    })

    {:ok, 0}
  end

  defp handle_invalid_draft_cluster(job, source_ids, run_id, decision_attrs, cluster_snapshot) do
    summary = "sources #{length(source_ids)} skipped due to invalid llm draft response"

    llm_cost_attrs = zero_cost_attrs()

    persist_decision(
      decision_attrs,
      "skipped_invalid_draft",
      nil,
      summary,
      llm_cost_attrs
    )

    persist_job_effect_event(job, %{
      decision_action: "skipped_invalid_draft",
      permanent_article_id: nil,
      process_run_id: run_id,
      source_ids: source_ids,
      source_input_snapshot: cluster_snapshot,
      change_summary: summary,
      change_details: %{
        source_count: length(source_ids),
        run_id: run_id,
        prompt_version: prompt_version(),
        llm_cost: llm_cost_attrs,
        reason: "invalid_llm_draft_response"
      },
      error_summary: nil
    })

    ignored_count = mark_sources_ignored(source_ids)
    {:ok, ignored_count}
  end

  defp build_article_attrs(cluster_sources) do
    primary = List.first(cluster_sources)
    summary_fallback = deterministic_article_summary(cluster_sources)
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
    case relevant_sources_for_draft(cluster_sources) do
      [] ->
        if has_full_content?(cluster_sources) do
          {:error, :no_relevant_sources}
        else
          {:error, :source_content_not_ready}
        end

      relevant_sources ->
        relevant_sources
        |> llm_prompt(rumour?)
        |> run_llm_draft()
    end
  end

  defp run_llm_draft(prompt) do
    # Run LLM draft generation in a supervised task so we can fail fast and retry quickly.
    case run_with_timeout(fn ->
           LLMClient.generate(prompt, timeout_ms: llm_draft_timeout_ms())
         end) do
      {:ok, %{text: text}} -> parse_and_record_draft(prompt, text)
      {:error, reason} -> {:error, reason}
      :timeout -> {:error, :timeout}
    end
  end

  defp run_with_timeout(fun) when is_function(fun, 0) do
    task = Task.async(fun)

    case Task.yield(task, llm_draft_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :timeout
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

    sanitized_headline = sanitize_plain_text_strict(headline)
    sanitized_summary = sanitize_plain_text_strict(summary)
    sanitized_body = sanitize_plain_text_strict(body)

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
    #{llm_source_notes(cluster_sources)}
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

  defp llm_source_notes(cluster_sources) do
    cluster_sources
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {source, idx} ->
      full_text =
        source.content
        |> sanitize_plain_text_strict()

      title =
        source.title
        |> sanitize_plain_text_strict()
        |> fallback_text("(untitled source)")

      provider = fallback_text(source.origin_provider, "unknown_provider")
      source_url = fallback_text(source.url, "(no_url)")

      """
      SOURCE #{idx}:
      PROVIDER: #{provider}
      URL: #{source_url}
      HEADLINE: #{title}
      FULL_TEXT:
      #{full_text}
      """
    end)
    |> then(&"Consider only these relevant source articles:\n\n#{&1}")
  end

  defp deterministic_article_summary(cluster_sources) do
    cluster_sources
    |> Enum.map_join("\n", fn source ->
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

  defp sanitize_plain_text_strict(summary) when is_binary(summary) do
    summary
    |> String.replace("\u00A0", " ")
    |> strip_html()
    |> String.replace("\u00A0", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\s+([,.;:!?])/, "\\1")
    |> String.trim()
  end

  defp sanitize_plain_text_strict(_), do: ""

  defp relevant_sources_for_draft(cluster_sources) do
    cluster_sources
    |> Enum.filter(fn source ->
      content = sanitize_plain_text_strict(source.content)
      title = sanitize_plain_text_strict(source.title)

      not blank?(content) and not blank?(title) and relevant_to_leigh?(source)
    end)
  end

  defp has_full_content?(cluster_sources) do
    Enum.any?(cluster_sources, fn source ->
      source.content
      |> sanitize_plain_text_strict()
      |> blank?()
      |> Kernel.not()
    end)
  end

  defp relevant_to_leigh?(source) do
    [source.title, source.content, source.body_summary]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> then(fn text ->
      Enum.any?(
        ["leigh", "leopards", "leythers", "adrian lam", "lam"],
        &String.contains?(text, &1)
      )
    end)
  end

  defp fallback_text(text, fallback) when is_binary(text) do
    if String.trim(text) == "", do: fallback, else: text
  end

  defp fallback_text(_text, fallback), do: fallback

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

  defp llm_draft_timeout_ms do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:llm_draft_timeout_ms, @default_llm_draft_timeout_ms)
  end

  defp dispatch_delay_ms do
    max_delay_ms =
      :leythers_com
      |> Application.get_env(:intelligence_generation, [])
      |> Keyword.get(:source_editorial_dispatch_delay_max_ms, @default_dispatch_delay_max_ms)
      |> normalize_non_negative_int(@default_dispatch_delay_max_ms)

    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:source_editorial_dispatch_delay_ms, @default_dispatch_delay_ms)
    |> normalize_non_negative_int(@default_dispatch_delay_ms)
    |> min(max_delay_ms)
  end

  defp normalize_non_negative_int(value, _default)
       when is_integer(value) and value >= 0,
       do: value

  defp normalize_non_negative_int(_value, default), do: default

  defp retry_base_seconds do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:source_editorial_retry_base_seconds, @default_retry_base_seconds)
  end

  defp retry_max_seconds do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:source_editorial_retry_max_seconds, @default_retry_max_seconds)
  end

  defp retry_persist_threshold do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(:source_editorial_retry_persist_threshold, @default_retry_persist_threshold)
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
