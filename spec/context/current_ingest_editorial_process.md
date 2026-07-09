# Current Ingest + Editorial Process

This document describes the ingest and automated editorial pipeline as it is currently implemented in code. It is intended to reflect real behavior in the application, including important constraints and gaps, rather than the earlier target architecture alone.

## Scope

The implementation described here covers:

1. Feed ingestion into `raw_sources`
2. Full-content fetch handoff for newly discovered sources
3. Raw source lifecycle transitions
4. Automated editorial processing into published AI articles
5. Homepage refresh orchestration after ingest or editorial updates
6. Current audit and observability surfaces for jobs and LLM calls

It does not cover manual publishing beyond where that path intersects with the automated editorial system.

## Core Data Flow

At a high level, the current automated pipeline is:

1. Configured feeds are enqueued into `LeythersCom.Ingestion.FetchRssFeedWorker`.
2. Feed items are normalized and upserted into `raw_sources` by URL.
3. Newly inserted sources trigger `LeythersCom.Ingestion.FetchSourceContentWorker` jobs.
4. Content fetch stores extracted article body text back onto `raw_sources.content`.
5. Feed ingestion and content fetch both enqueue `LeythersCom.Intelligence.SourceEditorialWorker`.
6. `SourceEditorialWorker` dispatches one cluster job per resulting topic cluster.
7. Each cluster job decides whether the source is ready, relevant, publishable, ignorable, or should remain pending.
8. Successful editorial output creates or updates `permanent_articles` and links sources through `article_sources`.
9. Editorial and ingest events trigger homepage reranking via `LeythersCom.Intelligence.EditorialOrchestrator`.

## Runtime Configuration

The main production-like defaults are currently defined in [config/config.exs](/Users/michael/Developer/elixir/leythers_com/config/config.exs).

Important values:

1. `:ingestion_feeds` contains three configured RSS providers:
   - Google News Leigh Leopards search
   - BBC Rugby League RSS
   - Serious About Rugby League RSS
2. `:intelligence_generation` currently defaults to:
   - `auto_generation_enabled: true`
   - `source_batch_size: 20`
   - `max_batches_per_run: 10`
   - `llm_draft_enabled: true`
   - `llm_significance_enabled: false`
   - `prompt_version: "source_editorial_v1"`
   - `similar_published_articles_limit: 15`
   - `article_similarity_update_threshold: 0.72`
   - `headline_recent_similarity_threshold: 0.90`
   - `min_llm_update_confidence: 0.80`
3. `:editorial_orchestration` currently defaults to:
   - `source_limit: 20`
   - `homepage_size: 12`
   - `refresh_cooldown_seconds: 300`
   - `async_source_refresh: true`
   - `prompt_version: "homepage_ranker_v1"`
4. Quantum schedules:
   - feed ingest every 30 minutes
   - stale-feed refresh every 6 hours
   - source-link health checks daily
   - editorial backlog enqueue hourly

Development overrides in [config/dev.exs](/Users/michael/Developer/elixir/leythers_com/config/dev.exs) lengthen timeouts and keep grouping disabled for easier local iteration.

## Ingestion Context

### Entry Points

The main ingest entry points live in [ingestion.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion.ex):

1. `ingest_configured_feeds/0`
2. `enqueue_feed_fetch/1`
3. `ingest_rss_feed/2`
4. `upsert_raw_source/1`
5. `fetch_and_store_content/1`

### Feed Worker

[fetch_rss_feed_worker.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion/fetch_rss_feed_worker.ex) is the Oban worker that executes a feed job.

Behavior:

1. Reads feed configuration from `job.args`.
2. Generates a `process_run_id` for diagnostics.
3. Calls `Ingestion.ingest_rss_feed/2`.
4. Persists a `job_effect_event` with a feed snapshot, processed counts, and any error.
5. Uses exponential-style retry backoff, with optional provider-specific multipliers from `:ingestion_monitoring` config.

### RSS Parsing and Upsert

`Ingestion.ingest_rss_feed/2` currently does the following:

1. Validates that the feed URL and `origin_provider` are present.
2. Fetches the feed body through the configured HTTP client.
3. Parses feed items with `LeythersCom.Ingestion.Providers.Rss`.
4. Optionally filters parsed items using configured `include_keywords`.
5. Reduces items through `reduce_feed_items/1`.

Each feed item is processed via `upsert_raw_source_tracked/1`:

1. The item is normalized with `LeythersCom.Ingestion.Providers.Basic.normalize/1`.
2. Insert happens with `on_conflict: :nothing` and `conflict_target: :url`.
3. Existing URL means `:seen`.
4. Newly inserted row means `:new`.
5. Insert failures count as `:error`.

Current dedupe rule:

1. URL is the canonical uniqueness boundary for `raw_sources`.
2. New stories are not merged at ingest time by title or content.
3. Canonicalization and cleanup happen before insert through the normalization layer, not later in editorial.

### Newly Created Raw Sources

When a source is newly inserted:

1. `EditorialOrchestrator.trigger_source_update_refresh/0` is called immediately.
2. The raw source ID is added to `stats.new_source_ids`.
3. `spawn_content_fetcher/1` enqueues a `FetchSourceContentWorker` for each new source.

This means ingest currently triggers both:

1. a homepage refresh signal, and
2. a later content-enrichment/editorial path.

### Full Content Fetch

The enrichment worker is [fetch_source_content_worker.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion/fetch_source_content_worker.ex).

Its job is simple:

1. receive a `source_id`
2. call `Ingestion.fetch_and_store_content/1`
3. return `:ok`

The actual fetch/extract logic is in [article_content_fetcher.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion/article_content_fetcher.ex).

Current extraction behavior:

1. Uses `Req.get/2` directly against the article URL.
2. Accepts only HTML-ish content types.
3. Rejects bodies larger than 2MB.
4. Extracts content from `article`, `main`, or common content/article/post class wrappers.
5. Falls back to full HTML if no preferred wrapper is found.
6. Strips scripts, styles, and tags.
7. Normalizes whitespace before storing.

### Raw Source Content Outcomes

`fetch_and_store_content/1` currently produces these outcomes:

1. If the source is missing: `:source_missing`
2. If extraction returns non-empty content:
   - update `raw_sources.content`
   - set `enrichment_status` to `ready`
   - reset enrichment failure counters
   - enqueue `SourceEditorialWorker` with `drain_backlog: true`
3. If extraction fails or content is blank:
   - set `last_checked_at`
   - set `last_check_status` to `broken`
   - keep `status` as `pending`
   - increment enrichment failure count
   - set `enrichment_status` to `queued` until terminal threshold
   - set `enrichment_status` to `failed` after 3 consecutive failures

This means content-fetch failures do not immediately ignore the source, but editorial dispatch now gates strictly on `enrichment_status = ready`, so failed/queued sources are not dispatched into editorial cluster jobs.

### Raw Source State Machine

[raw_source.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion/raw_source.ex) and [raw_source_status_machine.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion/raw_source_status_machine.ex) define the source lifecycle.

Valid statuses:

1. `pending`
2. `processed`
3. `ignored`

Allowed transitions:

1. `pending -> processed`
2. `pending -> ignored`
3. `processed -> pending`
4. `ignored -> pending`

Operational meaning:

1. `pending` means editorial still needs to make a decision.
2. `processed` means the source has already contributed to a publish/update path.
3. `ignored` means the source was intentionally skipped as irrelevant or invalid for editorial purposes.

## Current Editorial Path

### Worker Topology

The automated editorial pipeline is owned by [source_editorial_worker.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/intelligence/source_editorial_worker.ex).

It has two job modes:

1. dispatch jobs
2. cluster jobs

#### Dispatch Jobs

Dispatch jobs:

1. load pending sources in `external_published_at` order
2. require `enrichment_status = ready`
2. cap each batch by `source_batch_size`
3. cap recursive dispatch rounds by `max_batches_per_run`
4. build deterministic topic clusters
5. use optional bounded LLM similarity checks only for borderline comparisons
6. enqueue one cluster job per resulting cluster

Important current behavior:

1. Clustering is deterministic-first using title/content similarity and keyword overlap.
2. LLM grouping checks are only used for borderline pairs and are capped per dispatch batch.
3. Jobs remain traceable because each cluster task persists explicit `source_ids` for the grouped sources.
4. Cluster job dedupe is keyed by `task + source_ids + generation_settings` (not by run id), so the same cluster is not re-enqueued repeatedly in a short window.

#### Cluster Jobs

Cluster jobs:

1. re-fetch the source rows by ID
2. only include rows still in `pending`
3. compute significance, relevance, and draftability
4. attempt publish or update
5. mark sources `processed`, `ignored`, or leave them pending depending on outcome

### Budget Gate

Each cluster goes through `Intelligence.ensure_generation_allowed!/1` before drafting/publishing.

If budget is blocked:

1. a generation decision record is persisted as `skipped_budget`
2. a job effect event is recorded
3. processing halts for that cluster without publishing

### Significance Scoring

Every cluster computes a significance score.

Current implementation:

1. Deterministic significance scoring is always available.
2. Optional LLM-based significance exists via `llm_significance_score/1`.
3. `llm_significance_enabled` is currently `false` in the shared config.

In practice, the live path is currently deterministic significance scoring unless overridden.

### Relevance and Draftability

Before drafting, the worker evaluates whether the source is relevant to Leigh.

Current relevance test:

1. Concatenate title, full content, and summary.
2. Downcase the text.
3. Check for any of these markers:
   - `leigh`
   - `leopards`
   - `leythers`
   - `adrian lam`
   - `lam`

There are two closely related filters:

1. `relevant_sources_for_consideration/1`
   - checks topical relevance only
2. `relevant_sources_for_draft/1`
   - requires topical relevance plus non-empty full content plus non-empty title

This distinction matters:

1. A source can be relevant enough to consider but not draftable because full content is missing.
2. A source with summary only stays pending until content is available or another terminal outcome is reached.

### Editorial Context Assembly

For draftable relevant sources, `editorial_context/2` builds three context sections:

1. `incoming_sources`
2. `similar_raw_sources`
3. `similar_published_articles`

#### Incoming Sources

Each incoming source contributes:

1. ID
2. provider
3. URL
4. sanitized headline
5. truncated full text
6. sanitized summary
7. external published timestamp

#### Similar Raw Sources

Current lookup behavior:

1. Search recent `pending` and `processed` raw sources not already in the cluster.
2. Use lightweight similarity against the current source headline and combined source text.
3. Keep at most 8 similar raw sources.

#### Similar Published Articles

Current lookup behavior:

1. Read recent articles with sources through `Content.list_recent_articles_with_sources/1`.
2. Compare by title similarity, article-body similarity, or source-title overlap.
3. Keep at most 10 entries after filtering.
4. The overall query budget is bounded by `similar_published_articles_limit`, currently 15.

### LLM Draft Request

When `llm_draft_enabled` is true, the worker builds a single JSON-oriented prompt that asks the LLM to do both:

1. choose `new`, `update`, or `skip`
2. return final output fields

Requested response schema:

1. `action`
2. `target_article_id`
3. `reasoning`
4. `headline`
5. `summary`
6. `article_html`

The worker logs the prompt/context/response through `LeythersCom.Intelligence.LLMClient` into `llm_interaction_logs`, with purpose metadata `source_editorial_draft`.

### Draft Validation

LLM draft output is accepted only if it passes current quality gates.

Current enforced constraints include:

1. body text length at least 1,500 characters
2. at least 8 HTML paragraphs
3. headline not too similar to any source headline
4. headline not matching generic headline patterns
5. summary not matching generic summary patterns
6. body not matching generic body patterns
7. repeated generic phrasing is rejected

The output is then scored with `QualityRubric.score/1` and costed through `record_llm_cost/2`, which updates the daily `cost_ledgers` table.

### Update vs New Decision

Even if the draft payload already contains `action` and `target_article_id`, the worker runs a second guard step through `LeythersCom.Intelligence.DecisionEngine`.

Current behavior:

1. If the draft says `new` or `update`, the worker calls `DecisionEngine.decide_similarity_action/3`.
2. The decision engine is LLM-first, deterministic fallback second.
3. LLM update decisions must pass guardrails:
   - target article must exist in the shortlist
   - confidence must meet `min_llm_update_confidence`, currently 0.80
4. Otherwise the action is forced back to `:new`.

The decision-engine similarity call is also logged through `llm_interaction_logs` with purpose `decision_engine_similarity`.

### Deterministic Fallback Behavior

If LLM drafting is disabled entirely:

1. the worker publishes a deterministic summary-based article for relevant sources
2. it does not call the LLM draft path

If LLM drafting is enabled but errors occur:

1. some failures are terminal for the cluster
2. some failures allow deterministic fallback

Current behavior is:

1. `:source_content_not_ready`
   - source remains pending
2. `:no_relevant_sources`
   - source is marked ignored
3. `:invalid_llm_draft_response`
   - source remains pending
   - cluster is recorded as `skipped_validation`
   - bounded retries are attempted in-process before returning this outcome
4. hard LLM availability failures such as timeout, circuit open, rate limit, missing API key, transport failure, or request failure
   - source remains pending
   - no deterministic fallback is used
5. other non-terminal draft errors
   - deterministic fallback is allowed if there is some content or summary available

### Publish Outcomes

`publish_cluster_article/3` sends accepted attrs into `Content.publish_or_update_ai_article/3`.

That path currently does the following:

1. Normalizes the 3-part output into headline, summary, and body.
2. Rejects empty source ID lists.
3. Applies the `Voice` contract and validation layer.
4. Chooses create or update through `publish_or_update_ai_decision/6`.

Update resolution order:

1. explicit `target_article_id` if valid and published
2. otherwise recent published article match by:
   - title similarity threshold `0.6`
   - or source overlap
3. if no target is found, create a new AI article

Update side effects:

1. article version increments on published-article updates
2. missing source links are inserted without duplicating existing links
3. newly created articles get a new `story_id`

Successful publication side effects:

1. source rows are marked `processed`
2. `EditorialOrchestrator.trigger_source_update_refresh/0` is called
3. article generation decisions are persisted
4. job effect events are persisted

### Non-Publish Outcomes

Current cluster terminal outcomes are:

1. `skipped_budget`
2. `skipped_waiting_content`
3. `skipped_irrelevant`
4. `skipped_validation`
5. `skipped_publish_error`

Source-state behavior by outcome:

1. waiting for content: remains `pending`
2. irrelevant: transitions to `ignored`
3. invalid draft: remains `pending` for future retries/reprocessing
4. publish error after content-layer failure: source is marked `processed` to avoid infinite retry loops on validation/publish defects
5. LLM unavailable before publish: source remains pending

## Homepage Editorial Orchestration

[editorial_orchestrator.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/intelligence/editorial_orchestrator.ex) controls homepage reranking.

Current trigger points include:

1. new raw source insertion
2. successful AI publish or update
3. optional full rerank after dispatch backlog drains

### Refresh Behavior

`refresh_homepage_layout/1` currently:

1. loads recent articles with sources
2. collapses entries to one front article per story
3. ranks with `HomepageRanker.rank/2`
4. takes the configured homepage size
5. persists a `homepage_ranking_decisions` snapshot under a new `run_id`

### Cooldown and Async Refresh

`trigger_source_update_refresh/1` adds guardrails:

1. cache-backed cooldown, default 300 seconds
2. prevents overlapping refreshes
3. can enqueue an async refresh worker or run synchronously

### HomepageRanker

[homepage_ranker.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/intelligence/homepage_ranker.ex) currently applies:

1. recency score
2. optional LLM importance score for the top `llm_candidate_limit` entries
3. weighted hybrid score
4. novelty penalty
5. duplicate-story suppression

Important current details:

1. LLM importance is sparse and cached in ETS.
2. If the LLM is unavailable or missing API credentials, it falls back to deterministic importance.
3. Story duplication is reduced twice:
   - first by story collapse in `Content.collapse_entries_to_story_fronts/1`
   - then by text similarity dedupe inside `HomepageRanker`

LLM importance calls are logged through `llm_interaction_logs` with purpose `homepage_importance_ranking`.

## Observability and Audit Surfaces

There are now two main admin-facing audit surfaces.

### Job Operations

`job_effect_events` back the process-oriented job timeline in `/admin/jobs`.

These records capture:

1. Oban job identity and queue state
2. source snapshots
3. change summaries and details
4. selected publish outcomes
5. some embedded LLM prompt/output for older worker-level diagnostics

This surface is best for understanding pipeline execution and outcome history.

### LLM Interaction Logs

`llm_interaction_logs` back `/admin/llm-logs`.

These records capture every current shared-LLM-facade call, including:

1. adapter
2. model
3. status
4. attempt number
5. prompt
6. structured context
7. response text or error summary
8. metadata such as purpose and timeout-related values

This surface is best for inspecting prompt, context, and response bodies directly.

## Important Current Constraints and Caveats

These points are important for anyone modifying the pipeline:

1. The active editorial dispatcher uses `SourceClusterer` in the live path and enqueues one cluster job per resulting cluster (often multi-source).
2. `SourceClusterer` can use bounded LLM checks for borderline similarity and logs those calls with purpose `source_cluster_similarity`.
3. Full-content fetch failures keep sources pending rather than ignoring them immediately.
4. Relevance to Leigh is currently determined by straightforward keyword presence, not a richer entity model.
5. The LLM draft path requires substantial output quality before a draft is accepted.
6. Update-vs-new is effectively a two-stage process:
   - draft-level action suggestion
   - post-draft similarity decision guardrail
7. Homepage refresh is triggered from several places and protected by cooldown logic, so some source or editorial events may not cause an immediate rerank if one just ran.

## Files That Own the Current Behavior

Primary implementation files:

1. [lib/leythers_com/ingestion.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion.ex)
2. [lib/leythers_com/ingestion/fetch_rss_feed_worker.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion/fetch_rss_feed_worker.ex)
3. [lib/leythers_com/ingestion/fetch_source_content_worker.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion/fetch_source_content_worker.ex)
4. [lib/leythers_com/ingestion/article_content_fetcher.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion/article_content_fetcher.ex)
5. [lib/leythers_com/ingestion/raw_source_status_machine.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion/raw_source_status_machine.ex)
6. [lib/leythers_com/intelligence/source_editorial_worker.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/intelligence/source_editorial_worker.ex)
7. [lib/leythers_com/intelligence/decision_engine.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/intelligence/decision_engine.ex)
8. [lib/leythers_com/intelligence/homepage_ranker.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/intelligence/homepage_ranker.ex)
9. [lib/leythers_com/intelligence/editorial_orchestrator.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/intelligence/editorial_orchestrator.ex)
10. [lib/leythers_com/content.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/content.ex)

Admin visibility files:

1. [lib/leythers_com_web/live/admin/job_operations_live.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com_web/live/admin/job_operations_live.ex)
2. [lib/leythers_com_web/live/admin/llm_logs_live.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com_web/live/admin/llm_logs_live.ex)

## Practical Read Order

If you need to understand or change the current implementation quickly, read in this order:

1. [spec/context/current_ingest_editorial_process.md](/Users/michael/Developer/elixir/leythers_com/spec/context/current_ingest_editorial_process.md)
2. [lib/leythers_com/ingestion.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/ingestion.ex)
3. [lib/leythers_com/intelligence/source_editorial_worker.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/intelligence/source_editorial_worker.ex)
4. [lib/leythers_com/content.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/content.ex)
5. [lib/leythers_com/intelligence/editorial_orchestrator.ex](/Users/michael/Developer/elixir/leythers_com/lib/leythers_com/intelligence/editorial_orchestrator.ex)
