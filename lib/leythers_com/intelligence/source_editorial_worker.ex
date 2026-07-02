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
  alias LeythersCom.Intelligence.DecisionEngine
  alias LeythersCom.Intelligence.EditorialOrchestrator
  alias LeythersCom.Intelligence.LLMClient
  alias LeythersCom.Intelligence.StorySimilarity
  alias LeythersCom.Repo

  @default_batch_size 100
  @default_max_batches_per_run 100
  @default_significance_threshold 70
  @default_prompt_version "source_editorial_v1"
  @default_enqueue_unique_seconds 3_600
  @default_worker_timeout_ms 30_000
  @default_llm_draft_timeout_ms 7_500
  @default_llm_significance_timeout_ms 2_500
  @default_dispatch_delay_ms 2_000
  @default_dispatch_delay_max_ms 15_000
  @default_retry_base_seconds 1
  @default_retry_max_seconds 15
  @default_retry_persist_threshold 3
  @default_full_rerank_source_limit 200
  @default_full_rerank_homepage_size 12
  @min_article_body_chars 750
  @min_article_body_paragraphs 4
  @headline_source_similarity_threshold 0.82
  @headline_recent_similarity_threshold 0.72
  @article_similarity_update_threshold 0.45

  @generic_headline_patterns [
    "continue to impress",
    "latest news and updates",
    "current performance and upcoming matches",
    "look to make a statement",
    "face challenging weather conditions",
    "set for brutal weather challenge"
  ]

  @generic_summary_patterns [
    "the match is expected to be",
    "both teams have a lot to play for",
    "have been in impressive form lately",
    "looking to make a statement",
    "several wins in the super league"
  ]

  @generic_body_patterns [
    "looking to make a statement",
    "in impressive form lately",
    "a lot to play for"
  ]

  def enqueue(attrs \\ %{}) when is_map(attrs) do
    # Always use a canonical dispatch task key so that cluster tasks (which share
    # the same worker but carry different args) do not block new dispatch jobs
    # from being inserted via the uniqueness constraint.
    attrs = Map.new(attrs)

    attrs
    |> Map.put_new("task", "dispatch")
    |> Map.put_new("generation_settings", runtime_settings())
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
    Process.put(
      :leythers_com_source_editorial_runtime_settings,
      runtime_settings_from_job(job.args)
    )

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
    full_rerank? = Map.get(args, "full_rerank", drain_backlog?)
    run_id = Ecto.UUID.generate()

    dispatch_cluster_tasks(job, run_id, source_limit, max_batches, drain_backlog?, full_rerank?)
  end

  defp dispatch_cluster_tasks(
         _job,
         _run_id,
         _source_limit,
         max_batches,
         _drain_backlog?,
         _full_rerank?
       )
       when max_batches <= 0,
       do: :ok

  defp dispatch_cluster_tasks(
         job,
         run_id,
         source_limit,
         max_batches,
         drain_backlog?,
         full_rerank?
       ) do
    pending_sources = fetch_pending_sources(source_limit)

    case pending_sources do
      [] ->
        maybe_trigger_full_rerank(full_rerank?)
        :ok

      _ ->
        pending_sources
        |> enqueue_source_jobs(run_id)
        |> case do
          :ok ->
            maybe_continue_dispatch(
              job,
              run_id,
              source_limit,
              max_batches,
              drain_backlog?,
              full_rerank?
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp enqueue_source_jobs(pending_sources, run_id) do
    generation_settings = current_generation_settings()

    pending_sources
    |> Enum.map(&[&1])
    |> Enum.reduce_while(:ok, fn cluster, :ok ->
      case build_cluster_job(cluster, run_id, generation_settings) |> Oban.insert() do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_cluster_job(cluster, run_id, generation_settings) do
    source_ids = Enum.map(cluster, & &1.id)

    %{
      "task" => "cluster",
      "process_run_id" => run_id,
      "source_ids" => source_ids,
      "generation_settings" => generation_settings
    }
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

  defp maybe_continue_dispatch(
         _job,
         _run_id,
         _source_limit,
         _max_batches,
         false,
         _full_rerank?
       ),
       do: :ok

  defp maybe_continue_dispatch(
         _job,
         _run_id,
         _source_limit,
         max_batches,
         _drain_backlog?,
         _full_rerank?
       )
       when max_batches <= 1,
       do: :ok

  defp maybe_continue_dispatch(job, run_id, source_limit, max_batches, true, full_rerank?) do
    if oban_inline_testing?() do
      dispatch_cluster_tasks(job, run_id, source_limit, max_batches - 1, true, full_rerank?)
    else
      enqueue_dispatch_continuation(full_rerank?)
    end
  end

  defp oban_inline_testing? do
    :leythers_com
    |> Application.get_env(Oban, [])
    |> Keyword.get(:testing) == :inline
  end

  defp enqueue_dispatch_continuation(full_rerank?) do
    delay_seconds = div(dispatch_delay_ms(), 1_000) |> max(1)
    generation_settings = current_generation_settings()

    %{
      "task" => "dispatch",
      "generation_settings" => generation_settings,
      "full_rerank" => full_rerank?
    }
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

  defp maybe_trigger_full_rerank(true) do
    _ =
      EditorialOrchestrator.run_source_update_refresh(
        source_limit: full_rerank_source_limit(),
        homepage_size: full_rerank_homepage_size(),
        async: false
      )

    :ok
  end

  defp maybe_trigger_full_rerank(_), do: :ok

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
    started_at = System.monotonic_time()
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
              started_at: started_at,
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
            cluster_snapshot,
            started_at
          )

        {:error, :no_relevant_sources} ->
          handle_irrelevant_cluster(
            job,
            source_ids,
            run_id,
            decision_attrs,
            cluster_snapshot,
            started_at
          )

        {:error, :invalid_llm_draft_response} ->
          handle_invalid_draft_cluster(
            job,
            source_ids,
            run_id,
            decision_attrs,
            cluster_snapshot,
            started_at
          )

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

      emit_decision_telemetry(started_at, %{
        result: :ok,
        decision_action: "skipped_budget",
        triage_action: "budget_blocked",
        source_count: length(source_ids),
        significance_score: significance_score,
        significance_threshold: threshold,
        prompt_version: prompt_version(),
        llm_input_tokens: 0,
        llm_output_tokens: 0,
        target_article_id: nil
      })

      {:halt, :budget_blocked}
    end
  end

  defp publish_cluster_article(
         job,
         attrs,
         %{
           started_at: started_at,
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
    triage_action = Map.get(attrs, :triage_action, :new)
    target_article_id = Map.get(attrs, :target_article_id)
    decision_source = Map.get(attrs, :decision_source, "deterministic")
    decision_confidence = Map.get(attrs, :decision_confidence, 0.0)
    fallback_reason = Map.get(attrs, :fallback_reason)

    decision_attrs =
      decision_attrs
      |> Map.put(:decision_source, decision_source)
      |> Map.put(:decision_confidence, decision_confidence)
      |> Map.put(:fallback_reason, fallback_reason)

    if triage_action == :skip do
      summary =
        decision_summary(significance_score, threshold, source_ids, rumour?, llm_cost_attrs)

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
          significance_score: significance_score,
          significance_threshold: threshold,
          source_count: length(source_ids),
          run_id: run_id,
          prompt_version: prompt_version(),
          llm_cost: llm_cost_attrs,
          rumour: rumour?,
          decision_source: decision_source,
          decision_confidence: decision_confidence,
          fallback_reason: fallback_reason
        },
        error_summary: nil
      })

      emit_decision_telemetry(started_at, %{
        result: :ok,
        decision_action: "skipped_irrelevant",
        triage_action: "skip",
        source_count: length(source_ids),
        significance_score: significance_score,
        significance_threshold: threshold,
        prompt_version: prompt_version(),
        llm_input_tokens: llm_cost_attrs.input_tokens,
        llm_output_tokens: llm_cost_attrs.output_tokens,
        target_article_id: target_article_id,
        decision_source: decision_source,
        decision_confidence: decision_confidence,
        fallback_reason: fallback_reason
      })

      ignored_count = mark_sources_ignored(source_ids)
      {:ok, ignored_count}
    else
      case Content.publish_or_update_ai_article(attrs, source_ids,
             rumour: rumour?,
             triage_action: triage_action,
             target_article_id: target_article_id
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
              rumour: rumour?,
              decision_source: decision_source,
              decision_confidence: decision_confidence,
              fallback_reason: fallback_reason
            },
            error_summary: nil
          })

          emit_decision_telemetry(started_at, %{
            result: :ok,
            decision_action: action_str,
            triage_action: to_string(triage_action || action),
            source_count: length(source_ids),
            significance_score: significance_score,
            significance_threshold: threshold,
            prompt_version: prompt_version(),
            llm_input_tokens: llm_cost_attrs.input_tokens,
            llm_output_tokens: llm_cost_attrs.output_tokens,
            target_article_id: target_article_id,
            decision_source: decision_source,
            decision_confidence: decision_confidence,
            fallback_reason: fallback_reason,
            permanent_article_id: article.id
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
              rumour: rumour?,
              decision_source: decision_source,
              decision_confidence: decision_confidence,
              fallback_reason: fallback_reason
            },
            error_summary: inspect(reason)
          })

          emit_decision_telemetry(started_at, %{
            result: :error,
            decision_action: "skipped_publish_error",
            triage_action: to_string(triage_action),
            source_count: length(source_ids),
            significance_score: significance_score,
            significance_threshold: threshold,
            prompt_version: prompt_version(),
            llm_input_tokens: llm_cost_attrs.input_tokens,
            llm_output_tokens: llm_cost_attrs.output_tokens,
            target_article_id: target_article_id,
            decision_source: decision_source,
            decision_confidence: decision_confidence,
            fallback_reason: fallback_reason,
            error: inspect(reason)
          })

          # Mark sources as processed to avoid infinite loop on validation errors
          mark_sources_processed(source_ids)

          {:ok, 0}
      end
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

  defp handle_irrelevant_cluster(
         job,
         source_ids,
         run_id,
         decision_attrs,
         cluster_snapshot,
         started_at
       ) do
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

    emit_decision_telemetry(started_at, %{
      result: :ok,
      decision_action: "skipped_irrelevant",
      triage_action: "irrelevant_filter",
      source_count: length(source_ids),
      significance_score: nil,
      significance_threshold: nil,
      prompt_version: prompt_version(),
      llm_input_tokens: 0,
      llm_output_tokens: 0,
      target_article_id: nil
    })

    ignored_count = mark_sources_ignored(source_ids)
    {:ok, ignored_count}
  end

  defp handle_content_not_ready_cluster(
         job,
         source_ids,
         run_id,
         decision_attrs,
         cluster_snapshot,
         started_at
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

    emit_decision_telemetry(started_at, %{
      result: :ok,
      decision_action: "skipped_waiting_content",
      triage_action: "waiting_content",
      source_count: length(source_ids),
      significance_score: nil,
      significance_threshold: nil,
      prompt_version: prompt_version(),
      llm_input_tokens: 0,
      llm_output_tokens: 0,
      target_article_id: nil
    })

    {:ok, 0}
  end

  defp handle_invalid_draft_cluster(
         job,
         source_ids,
         run_id,
         decision_attrs,
         cluster_snapshot,
         started_at
       ) do
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

    emit_decision_telemetry(started_at, %{
      result: :ok,
      decision_action: "skipped_invalid_draft",
      triage_action: "invalid_draft",
      source_count: length(source_ids),
      significance_score: nil,
      significance_threshold: nil,
      prompt_version: prompt_version(),
      llm_input_tokens: 0,
      llm_output_tokens: 0,
      target_article_id: nil
    })

    ignored_count = mark_sources_ignored(source_ids)
    {:ok, ignored_count}
  end

  defp build_article_attrs(cluster_sources) do
    primary = List.first(cluster_sources)
    summary_fallback = deterministic_article_summary(cluster_sources)
    rumour? = rumour_cluster?(cluster_sources)
    relevant_sources = relevant_sources_for_consideration(cluster_sources)

    cond do
      relevant_sources == [] and has_full_content_or_summary?(cluster_sources) ->
        {:error, :no_relevant_sources}

      relevant_sources == [] ->
        {:error, :source_content_not_ready}

      llm_draft_enabled?() ->
        llm_draft_attrs(cluster_sources, rumour?)

      true ->
        {:ok,
         %{
           triage_action: nil,
           target_article_id: nil,
           headline: primary.title,
           summary: summary_fallback,
           body_html: simple_html_from_text(summary_fallback)
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
        context = editorial_context(cluster_sources, relevant_sources)
        source_headlines = source_headlines_for_guardrails(cluster_sources)

        context
        |> llm_prompt(rumour?)
        |> run_llm_draft(
          runtime_setting(:llm_config, LLMClient.llm_config()) |> Enum.into([]),
          source_headlines,
          context
        )
    end
  end

  defp run_llm_draft(prompt, llm_config, source_headlines, context) do
    # Run LLM draft generation in a supervised task so we can fail fast and retry quickly.
    case run_with_timeout(fn ->
           LLMClient.generate(prompt,
             timeout_ms: llm_draft_timeout_ms(),
             llm_config: llm_config
           )
         end) do
      {:ok, %{text: text}} -> parse_and_record_draft(prompt, text, source_headlines, context)
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

  defp parse_and_record_draft(prompt, text, source_headlines, context) do
    case parse_structured_editorial_response(text) do
      {:ok, attrs} ->
        case validate_draft_quality(attrs, source_headlines) do
          :ok ->
            final_attrs = reconcile_similarity_action(attrs, context)
            llm_cost_attrs = record_llm_cost(prompt, text)
            {:ok, final_attrs, llm_cost_attrs}

          _ ->
            {:error, :invalid_llm_draft_response}
        end

      _ ->
        {:error, :invalid_llm_draft_response}
    end
  end

  defp llm_prompt(context, rumour?) do
    context_json = Jason.encode!(context)

    """
    You are the Leythers editorial orchestrator. Use the provided JSON context to do two jobs together:
    1) Decide whether to create a new article or update an existing published article.
    2) Produce the final output package for publishing.

    Decision rules:
    - Similarity and update-vs-new must be decided BEFORE writing output.
    - Use all context sections: incoming_sources, similar_raw_sources, similar_published_articles.
    - Assume readers already know Leigh Leopards; do not repeatedly explain they are a rugby league team.
    - Prefer updating an existing published article when the incoming story is the same evolving topic.
    - If any similar_published_articles item overlaps heavily in facts, entities, or match context, choose "update" and set target_article_id.
    - Create a new article when the incoming story is materially different.
    - Use only facts contained in the provided context.
    - #{if rumour?, do: "Treat this as rumour-sensitive and mark uncertainty carefully.", else: "Write with factual confidence where supported by context."}

    Output requirements:
    - Return exactly one JSON object.
    - headline must be plain text and in Leythers voice.
    - headline must NOT be a rewrite/copy of any source headline and must NOT include source/publisher attribution.
    - summary must be plain text.
    - article_html must be valid HTML (use semantic tags like <p>, optional <h2>, <ul>, <li>). No markdown.
    - article_html must contain at least 4 informative paragraphs with concrete details from context; avoid filler lines.
    - article_html should synthesize facts from the full_text fields in the context where available, not just source headlines.
    - target_article_id should be a published article id from similar_published_articles when action is "update".

    JSON schema:
    {
      "action": "new" | "update" | "skip",
      "target_article_id": "<uuid-or-null>",
      "reasoning": "<brief plain text rationale>",
      "headline": "<plain text max 100 chars>",
      "summary": "<plain text max 280 chars>",
      "article_html": "<html string max 12000 chars>"
    }

    CONTEXT_JSON:
    #{context_json}
    """
  end

  defp parse_structured_editorial_response(text) when is_binary(text) do
    with {:ok, payload} <- decode_structured_payload(text),
         {:ok, action} <- parse_editorial_action(payload),
         {:ok, attrs} <- extract_editorial_attrs(payload, action) do
      {:ok, attrs}
    else
      _ ->
        parse_legacy_llm_draft(text)
    end
  end

  defp parse_structured_editorial_response(_text), do: :error

  defp decode_structured_payload(text) when is_binary(text) do
    json_candidate =
      text
      |> String.trim()
      |> strip_code_fence()
      |> extract_json_block()

    case Jason.decode(json_candidate) do
      {:ok, %{} = payload} -> {:ok, payload}
      _ -> :error
    end
  end

  defp parse_editorial_action(payload) do
    action = payload["action"] |> sanitize_plain_text_strict() |> String.downcase()

    case action do
      "new" -> {:ok, :new}
      "update" -> {:ok, :update}
      "skip" -> {:ok, :skip}
      _ -> :error
    end
  end

  defp extract_editorial_attrs(_payload, :skip) do
    {:ok,
     %{
       triage_action: :skip,
       target_article_id: nil,
       headline: "",
       summary: "",
       body_html: ""
     }}
  end

  defp extract_editorial_attrs(payload, action) when action in [:new, :update] do
    headline = payload["headline"] |> sanitize_plain_text_strict() |> String.slice(0, 100)
    summary = payload["summary"] |> sanitize_plain_text_strict() |> String.slice(0, 280)
    body_html = payload["article_html"] |> sanitize_html_strict() |> String.slice(0, 12_000)

    target_article_id =
      payload["target_article_id"]
      |> sanitize_plain_text_strict()
      |> normalize_target_article_id()

    if blank?(headline) or blank?(summary) or blank?(body_html) do
      :error
    else
      {:ok,
       %{
         triage_action: action,
         target_article_id: target_article_id,
         headline: headline,
         summary: summary,
         body_html: body_html
       }}
    end
  end

  defp parse_legacy_llm_draft(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {headline, summary, body} = extract_legacy_draft_parts(lines)

    sanitized_headline = sanitize_plain_text_strict(headline)
    sanitized_summary = sanitize_plain_text_strict(summary)
    sanitized_body_html = body |> sanitize_plain_text_strict() |> simple_html_from_text()

    if blank?(sanitized_headline) or blank?(sanitized_summary) do
      :error
    else
      {:ok,
       %{
         triage_action: :new,
         target_article_id: nil,
         headline: String.slice(sanitized_headline, 0, 100),
         summary: String.slice(sanitized_summary, 0, 280),
         body_html: String.slice(sanitized_body_html, 0, 12_000)
       }}
    end
  end

  defp extract_legacy_draft_parts(lines) do
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

  defp strip_code_fence(text) do
    text
    |> String.replace_prefix("```json", "")
    |> String.replace_prefix("```", "")
    |> String.replace_suffix("```", "")
    |> String.trim()
  end

  defp extract_json_block(text) do
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json] -> json
      _ -> text
    end
  end

  defp normalize_target_article_id(""), do: nil
  defp normalize_target_article_id("none"), do: nil

  defp normalize_target_article_id(id) do
    if Regex.match?(~r/^[0-9a-fA-F-]{36}$/, id), do: id, else: nil
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

  defp editorial_context(cluster_sources, relevant_sources) do
    %{
      incoming_sources: format_sources_for_context(relevant_sources),
      similar_raw_sources:
        find_similar_raw_sources(cluster_sources) |> format_sources_for_context(),
      similar_published_articles:
        find_similar_published_articles(cluster_sources)
        |> Enum.map(&format_article_entry_for_context/1)
    }
  end

  defp format_sources_for_context(sources) do
    Enum.map(sources, fn source ->
      %{
        id: source.id,
        origin_provider: fallback_text(source.origin_provider, "unknown_provider"),
        url: fallback_text(source.url, "(no_url)"),
        headline:
          source.title |> sanitize_plain_text_strict() |> fallback_text("(untitled source)"),
        full_text: source.content |> sanitize_plain_text_strict() |> truncate_for_prompt(3_500),
        summary:
          source.body_summary
          |> sanitize_plain_text_strict()
          |> fallback_text("no summary available"),
        external_published_at: format_dt(source.external_published_at)
      }
    end)
  end

  defp find_similar_raw_sources(cluster_sources) do
    current_ids = Enum.map(cluster_sources, & &1.id)

    reference_text =
      cluster_sources
      |> Enum.map_join("\n", fn source ->
        [source.title, source.content, source.body_summary]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")
      end)
      |> sanitize_plain_text_strict()

    RawSource
    |> where([source], source.id not in ^current_ids)
    |> where([source], source.status in ["pending", "processed"])
    |> order_by([source], desc: source.external_published_at, desc: source.inserted_at)
    |> limit(80)
    |> Repo.all()
    |> Enum.filter(fn source ->
      StorySimilarity.similar?(source.title || "", List.first(cluster_sources).title || "", 0.35) or
        StorySimilarity.score(reference_text, similarity_text_for_source(source)) >= 0.3
    end)
    |> Enum.take(8)
  end

  defp similarity_text_for_source(source) do
    [source.title, source.content, source.body_summary]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> sanitize_plain_text_strict()
  end

  defp find_similar_published_articles(cluster_sources) do
    reference_headline = List.first(cluster_sources).title || ""
    reference_text = cluster_sources |> Enum.map_join("\n", &similarity_text_for_source/1)

    entries = Content.list_recent_articles_with_sources(30)

    similar_entries =
      Enum.filter(entries, fn entry ->
        article = entry.article

        StorySimilarity.similar?(article.title || "", reference_headline, 0.2) or
          StorySimilarity.score(article_similarity_text(article), reference_text) >= 0.2 or
          similar_source_title_overlap?(entry.sources, cluster_sources)
      end)

    if similar_entries == [] do
      entries |> Enum.take(10)
    else
      similar_entries |> Enum.take(10)
    end
  end

  defp article_similarity_text(article) do
    [article.title, article.summary, article.body]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> sanitize_plain_text_strict()
  end

  defp similar_source_title_overlap?(article_sources, cluster_sources) do
    incoming_titles = Enum.map(cluster_sources, &(&1.title || ""))

    Enum.any?(article_sources, fn source ->
      Enum.any?(incoming_titles, fn incoming_title ->
        StorySimilarity.similar?(source.title || "", incoming_title, 0.4)
      end)
    end)
  end

  defp format_article_entry_for_context(entry) do
    %{
      article_id: entry.article.id,
      author_type: entry.article.author_type,
      headline: entry.article.title |> sanitize_plain_text_strict(),
      summary: entry.article.summary |> sanitize_plain_text_strict(),
      article_html: sanitize_html_strict(entry.article.body),
      source_links:
        Enum.map(entry.sources, fn source ->
          %{
            id: source.id,
            title: source.title |> sanitize_plain_text_strict(),
            url: source.url,
            origin_provider: source.origin_provider
          }
        end)
    }
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

  defp simple_html_from_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.split("\n", trim: true)
    |> Enum.map_join("", fn line -> "<p>#{line}</p>" end)
  end

  defp simple_html_from_text(_text), do: ""

  defp sanitize_html_strict(html) when is_binary(html) do
    cleaned =
      html
      |> String.replace(~r/<script[\s\S]*?<\/script>/i, "")
      |> String.replace(~r/\son[a-z]+=\"[^\"]*\"/i, "")
      |> String.replace(~r/\son[a-z]+='[^']*'/i, "")
      |> String.replace(~r/javascript:/i, "")
      |> String.trim()

    if Regex.match?(~r/<[^>]+>/, cleaned) do
      cleaned
    else
      cleaned |> sanitize_plain_text_strict() |> simple_html_from_text()
    end
  end

  defp sanitize_html_strict(_html), do: ""

  defp source_headlines_for_guardrails(cluster_sources) do
    cluster_sources
    |> Enum.map(&sanitize_plain_text_strict(&1.title))
    |> Enum.reject(&blank?/1)
  end

  defp validate_draft_quality(attrs, source_headlines) when is_map(attrs) do
    body_html = Map.get(attrs, :body_html, "")
    headline = Map.get(attrs, :headline, "")
    summary = Map.get(attrs, :summary, "")

    body_text_len =
      body_html
      |> strip_html()
      |> sanitize_plain_text_strict()
      |> String.length()

    paragraph_count =
      Regex.scan(~r/<p\b[^>]*>/i, body_html)
      |> length()

    cond do
      body_text_len < @min_article_body_chars ->
        {:error, :body_too_short}

      paragraph_count < @min_article_body_paragraphs ->
        {:error, :body_not_detailed_enough}

      copied_source_headline?(headline, source_headlines) ->
        {:error, :headline_too_similar_to_source}

      generic_headline?(headline) ->
        {:error, :headline_too_generic}

      generic_summary?(summary) ->
        {:error, :summary_too_generic}

      generic_body?(body_html) ->
        {:error, :body_too_generic}

      repeated_generic_phrase?(body_html) ->
        {:error, :generic_phrasing_repeated}

      true ->
        :ok
    end
  end

  defp copied_source_headline?(headline, source_headlines) do
    normalized_headline = sanitize_plain_text_strict(headline)

    normalized_headline != "" and
      Enum.any?(source_headlines, fn source_headline ->
        StorySimilarity.similar?(
          normalized_headline,
          source_headline,
          @headline_source_similarity_threshold
        )
      end)
  end

  defp generic_headline?(headline) do
    normalized =
      headline
      |> sanitize_plain_text_strict()
      |> String.downcase()

    String.starts_with?(normalized, "leigh leopards") and
      Enum.any?(@generic_headline_patterns, &String.contains?(normalized, &1))
  end

  defp generic_summary?(summary) do
    normalized =
      summary
      |> sanitize_plain_text_strict()
      |> String.downcase()

    Enum.any?(@generic_summary_patterns, &String.contains?(normalized, &1))
  end

  defp generic_body?(body_html) do
    normalized =
      body_html
      |> strip_html()
      |> sanitize_plain_text_strict()
      |> String.downcase()

    Enum.any?(@generic_body_patterns, &String.contains?(normalized, &1))
  end

  defp repeated_generic_phrase?(body_html) do
    body_text =
      body_html
      |> strip_html()
      |> sanitize_plain_text_strict()
      |> String.downcase()

    phrase_count =
      Regex.scan(~r/\brugby league team\b/, body_text)
      |> length()

    phrase_count > 1
  end

  defp reconcile_similarity_action(attrs, %{similar_published_articles: entries})
       when is_map(attrs) and is_list(entries) do
    normalized_action = Map.get(attrs, :triage_action)

    if normalized_action in [:new, :update] do
      case DecisionEngine.decide_similarity_action(
             attrs,
             entries,
             llm_enabled: llm_draft_enabled?(),
             article_similarity_update_threshold: @article_similarity_update_threshold,
             headline_recent_similarity_threshold: @headline_recent_similarity_threshold,
             llm_timeout_ms: llm_draft_timeout_ms()
           ) do
        {:ok, decision} ->
          attrs
          |> Map.put(:triage_action, Map.get(decision, :triage_action, normalized_action))
          |> Map.put(:target_article_id, Map.get(decision, :target_article_id))
          |> Map.put(:decision_source, Map.get(decision, :decision_source, "deterministic"))
          |> Map.put(:decision_confidence, Map.get(decision, :decision_confidence, 0.0))
          |> Map.put(:fallback_reason, Map.get(decision, :fallback_reason))
      end
    else
      attrs
    end
  end

  defp reconcile_similarity_action(attrs, _context), do: attrs

  defp relevant_sources_for_draft(cluster_sources) do
    cluster_sources
    |> Enum.filter(fn source ->
      content = sanitize_plain_text_strict(source.content)
      title = sanitize_plain_text_strict(source.title)

      not blank?(content) and not blank?(title) and relevant_to_leigh?(source)
    end)
  end

  defp relevant_sources_for_consideration(cluster_sources) do
    Enum.filter(cluster_sources, &relevant_to_leigh?/1)
  end

  defp has_full_content?(cluster_sources) do
    Enum.any?(cluster_sources, fn source ->
      source.content
      |> sanitize_plain_text_strict()
      |> blank?()
      |> Kernel.not()
    end)
  end

  defp has_full_content_or_summary?(cluster_sources) do
    Enum.any?(cluster_sources, fn source ->
      content_present? =
        source.content
        |> sanitize_plain_text_strict()
        |> blank?()
        |> Kernel.not()

      summary_present? =
        source.body_summary
        |> sanitize_plain_text_strict()
        |> blank?()
        |> Kernel.not()

      content_present? or summary_present?
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
    if llm_significance_enabled?() do
      case llm_significance_score(cluster_sources) do
        {:ok, score} -> score
        :error -> deterministic_significance_score(cluster_sources)
      end
    else
      deterministic_significance_score(cluster_sources)
    end
  end

  defp llm_significance_score(cluster_sources) do
    prompt = significance_prompt(cluster_sources)
    llm_config = runtime_setting(:llm_config, LLMClient.llm_config()) |> Enum.into([])

    case run_with_timeout(fn ->
           LLMClient.generate(prompt,
             timeout_ms: llm_significance_timeout_ms(),
             llm_config: llm_config
           )
         end) do
      {:ok, {:ok, %{text: text}}} -> parse_numeric_score(text)
      _ -> :error
    end
  end

  defp significance_prompt(cluster_sources) do
    notes =
      cluster_sources
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {source, idx} ->
        title = source.title |> sanitize_plain_text_strict() |> fallback_text("(untitled)")
        provider = fallback_text(source.origin_provider, "unknown_provider")
        "#{idx}. [#{provider}] #{title}"
      end)

    """
    Score editorial significance for Leigh Leopards supporters from 0 to 100.
    Return only one integer.

    Source notes:
    #{notes}
    """
  end

  defp parse_numeric_score(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      Regex.match?(~r/^(100|[1-9]?\d)$/, trimmed) ->
        {:ok, String.to_integer(trimmed)}

      match = Regex.run(~r/\bscore\b[^0-9]*(100|[1-9]?\d)\b/i, text) ->
        [_, value] = match
        {:ok, String.to_integer(value)}

      match = Regex.run(~r/\b(100|[1-9]?\d)\s*\/\s*100\b/, text) ->
        [_, value] = match
        {:ok, String.to_integer(value)}

      true ->
        :error
    end
  end

  defp parse_numeric_score(_), do: :error

  defp deterministic_significance_score(cluster_sources) do
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
    runtime_setting(:auto_generation_enabled, true)
  end

  defp llm_draft_enabled? do
    runtime_setting(:llm_draft_enabled, true)
  end

  defp llm_cost_per_1k_tokens_gbp do
    runtime_setting(:llm_cost_per_1k_tokens_gbp, "0.000000")
    |> Decimal.new()
  end

  defp default_batch_size do
    runtime_setting(:source_batch_size, @default_batch_size)
  end

  defp max_batches_per_run do
    runtime_setting(:max_batches_per_run, @default_max_batches_per_run)
  end

  defp significance_threshold do
    runtime_setting(:significance_threshold, @default_significance_threshold)
  end

  defp prompt_version do
    runtime_setting(:prompt_version, @default_prompt_version)
  end

  defp enqueue_unique_seconds do
    runtime_setting(:source_editorial_enqueue_unique_seconds, @default_enqueue_unique_seconds)
  end

  defp worker_timeout_ms do
    runtime_setting(:source_editorial_worker_timeout_ms, @default_worker_timeout_ms)
  end

  defp llm_draft_timeout_ms do
    runtime_setting(:llm_draft_timeout_ms, @default_llm_draft_timeout_ms)
  end

  defp llm_significance_enabled? do
    runtime_setting(:llm_significance_enabled, true)
  end

  defp llm_significance_timeout_ms do
    runtime_setting(:llm_significance_timeout_ms, @default_llm_significance_timeout_ms)
  end

  defp dispatch_delay_ms do
    max_delay_ms =
      runtime_setting(:source_editorial_dispatch_delay_max_ms, @default_dispatch_delay_max_ms)
      |> normalize_non_negative_int(@default_dispatch_delay_max_ms)

    runtime_setting(:source_editorial_dispatch_delay_ms, @default_dispatch_delay_ms)
    |> normalize_non_negative_int(@default_dispatch_delay_ms)
    |> min(max_delay_ms)
  end

  defp normalize_non_negative_int(value, _default)
       when is_integer(value) and value >= 0,
       do: value

  defp normalize_non_negative_int(_value, default), do: default

  defp retry_base_seconds do
    runtime_setting(:source_editorial_retry_base_seconds, @default_retry_base_seconds)
  end

  defp retry_max_seconds do
    runtime_setting(:source_editorial_retry_max_seconds, @default_retry_max_seconds)
  end

  defp retry_persist_threshold do
    runtime_setting(:source_editorial_retry_persist_threshold, @default_retry_persist_threshold)
  end

  defp full_rerank_source_limit do
    runtime_setting(:full_rerank_source_limit, @default_full_rerank_source_limit)
  end

  defp full_rerank_homepage_size do
    runtime_setting(:full_rerank_homepage_size, @default_full_rerank_homepage_size)
  end

  defp runtime_settings do
    %{
      auto_generation_enabled: read_generation_setting(:auto_generation_enabled, true),
      llm_draft_enabled: read_generation_setting(:llm_draft_enabled, true),
      llm_cost_per_1k_tokens_gbp:
        read_generation_setting(:llm_cost_per_1k_tokens_gbp, "0.000000"),
      source_batch_size: read_generation_setting(:source_batch_size, @default_batch_size),
      max_batches_per_run:
        read_generation_setting(:max_batches_per_run, @default_max_batches_per_run),
      significance_threshold:
        read_generation_setting(:significance_threshold, @default_significance_threshold),
      prompt_version: read_generation_setting(:prompt_version, @default_prompt_version),
      source_editorial_enqueue_unique_seconds:
        read_generation_setting(
          :source_editorial_enqueue_unique_seconds,
          @default_enqueue_unique_seconds
        ),
      source_editorial_worker_timeout_ms:
        read_generation_setting(:source_editorial_worker_timeout_ms, @default_worker_timeout_ms),
      llm_draft_timeout_ms:
        read_generation_setting(:llm_draft_timeout_ms, @default_llm_draft_timeout_ms),
      llm_significance_enabled: read_generation_setting(:llm_significance_enabled, true),
      llm_significance_timeout_ms:
        read_generation_setting(
          :llm_significance_timeout_ms,
          @default_llm_significance_timeout_ms
        ),
      source_editorial_dispatch_delay_ms:
        read_generation_setting(:source_editorial_dispatch_delay_ms, @default_dispatch_delay_ms),
      source_editorial_dispatch_delay_max_ms:
        read_generation_setting(
          :source_editorial_dispatch_delay_max_ms,
          @default_dispatch_delay_max_ms
        ),
      source_editorial_retry_base_seconds:
        read_generation_setting(:source_editorial_retry_base_seconds, @default_retry_base_seconds),
      source_editorial_retry_max_seconds:
        read_generation_setting(:source_editorial_retry_max_seconds, @default_retry_max_seconds),
      source_editorial_retry_persist_threshold:
        read_generation_setting(
          :source_editorial_retry_persist_threshold,
          @default_retry_persist_threshold
        ),
      full_rerank_source_limit:
        read_generation_setting(:full_rerank_source_limit, @default_full_rerank_source_limit),
      full_rerank_homepage_size:
        read_generation_setting(:full_rerank_homepage_size, @default_full_rerank_homepage_size),
      llm_config: LLMClient.llm_config() |> Map.new()
    }
  end

  defp runtime_settings_from_job(args) when is_map(args) do
    case Map.get(args, "generation_settings") do
      %{} = generation_settings ->
        Map.merge(runtime_settings(), normalize_settings_map(generation_settings))

      _other ->
        runtime_settings()
    end
  end

  defp runtime_settings_from_job(_args), do: runtime_settings()

  defp current_generation_settings do
    Process.get(:leythers_com_source_editorial_runtime_settings) || runtime_settings()
  end

  defp runtime_setting(key, default) do
    runtime_settings = Process.get(:leythers_com_source_editorial_runtime_settings)

    case runtime_settings do
      %{} = settings -> Map.get(settings, key, default)
      _other -> read_generation_setting(key, default)
    end
  end

  defp read_generation_setting(key, default) do
    :leythers_com
    |> Application.get_env(:intelligence_generation, [])
    |> Keyword.get(key, default)
  end

  defp normalize_settings_map(settings) when is_map(settings) do
    Enum.reduce(settings, %{}, fn {key, value}, acc ->
      normalized_key = normalize_setting_key(key)
      normalized_value = normalize_setting_value(normalized_key, value)
      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_settings_map(settings) when is_list(settings) do
    settings |> Map.new() |> normalize_settings_map()
  end

  defp normalize_settings_map(_settings), do: %{}

  defp normalize_setting_key(key) when is_atom(key), do: key

  defp normalize_setting_key(key) when is_binary(key) do
    string_to_existing_atom(key) || key
  end

  defp normalize_setting_key(key), do: key

  defp normalize_setting_value(:llm_config, value) when is_map(value),
    do: normalize_settings_map(value)

  defp normalize_setting_value(:llm_config, value) when is_list(value),
    do: normalize_settings_map(value)

  defp normalize_setting_value(:llm_config, value), do: value

  defp normalize_setting_value(:adapter, value) when is_binary(value) do
    string_to_existing_atom(value) || value
  end

  defp normalize_setting_value(_key, value), do: value

  defp string_to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
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

  defp emit_decision_telemetry(started_at, metadata) when is_map(metadata) do
    safe_metadata =
      metadata
      |> Map.put_new(:result, :ok)
      |> Map.put_new(:decision_action, "unknown")
      |> Map.put_new(:triage_action, "unknown")
      |> Map.put_new(:source_count, 0)
      |> Map.put_new(:prompt_version, prompt_version())
      |> Map.put_new(:llm_input_tokens, 0)
      |> Map.put_new(:llm_output_tokens, 0)

    :telemetry.execute(
      [:leythers_com, :intelligence, :source_editorial, :decision, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      safe_metadata
    )

    :ok
  end
end
