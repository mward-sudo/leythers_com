# Implementation Plan (Product-Aligned Roadmap)

## Product Intent

Leythers.com exists to aggregate Leigh Leopards news and rumours, then present that material in a
distinct editorial voice.

The implementation strategy is:

1. Keep the manual publishing path first-class and always available.
2. Use low/no-cost aggregation and summarization first.
3. Use LLM as the key decision-maker for homepage layout and article create/update decisions, but
   invoke it only when value justifies cost.
4. Start with a single technical author workflow, while designing data and permissions so future
   multi-author support can be added without schema churn.

## Operating Principles

1. Cost-first execution: prefer deterministic pipelines, cached transforms, and reusable summaries
   before paid model calls.
2. Voice consistency over raw volume: publishing quality and recognizable tone are more important
   than frequent low-quality output.
3. Human override always available: the admin can always publish directly without queue/model
   dependency.
4. Progressive complexity: keep initial CMS/editorial workflow simple, then add collaboration only
   when needed.
5. LLM is authoritative for editorial ranking/update decisions, with strict invocation controls and
   full audit trails.

## Immediate Execution Priority

Goals:

1. Prioritize real-data reliability before adding non-critical tooling surfaces.

Tasks:

1. Expand and verify live web ingestion sources (RSS/HTML) with production-like payloads.
2. Harden extraction quality against noisy markup and partial feeds.
3. Improve source health checks, retry policy, and canonical URL handling for real-world failures.
4. Add provenance validation checks to ensure stored source metadata matches fetched content.
5. Keep dashboard enhancements deferred until ingestion coverage and data quality gates are stable.

Deliverables:

1. Homepage and article workflows are fed by dependable real web data.
2. Operational confidence in ingestion quality is established before dashboard expansion.

Execution backlog (ordered):

1. Validate live ingestion end-to-end using Leigh-focused feeds and confirm stable dedupe/canonical
   behavior under repeated polls.
2. Improve extraction quality with provider-specific cleanup rules and regression fixtures from
   real payloads.
3. Add ingestion reliability controls: per-feed telemetry, failure backoff policy, and stale-feed
   alert thresholds.
4. Tighten editorial automation on real data by tuning update-vs-create clustering logic against
   noisy titles.
5. Add admin diagnostics dashboard after ingestion stability gates are met, focused on feed health,
   ranking runs, and fallback rates.

## Phase A: Core Platform Baseline (Completed)

Goals:

1. Establish dependable ingestion, publishing, and budget primitives.

Delivered:

1. Core tables and schemas for sources, articles, attribution links, and cost ledgers.
2. Manual fast-track publish flow with optional source links.
3. Scheduled ingestion with canonicalization and source health checks.
4. Budget guardrails for AI generation (monthly cap + near-cap warning semantics).
5. Authenticated admin surfaces, provenance and cost visibility, telemetry, dead-letter retries, and
   deployment hardening.

## Phase B: Editorial Voice Engine (Next Priority)

Goals:

1. Make the site output feel intentionally "Leythers" rather than generic summaries.

Tasks:

1. Define an explicit voice guide (rough fan style, irreverent humour, sentence rhythm, rumour
   framing rules).
2. Add a `voice profile` configuration layer that can be applied to manual and generated content.
3. Implement deterministic style transforms that run without LLM cost where possible.
4. Add preview tooling in admin to compare "raw summary" vs "voice-adjusted" output.
5. Add tests to lock down headline/body style constraints, rumour labeling behavior, and prevent
   drift.

Deliverables:

1. Consistent site voice across manually authored and automated content.
2. Voice rules are versioned, testable, and easy to tune.

## Phase C: Cost-Optimized Aggregation Pipeline (Next Priority)

Goals:

1. Maximize useful content coverage while minimizing paid-token spend.

Tasks:

1. Introduce a summarization strategy ladder:
   - Rule-based extraction and truncation (free)
   - Heuristic/templated synthesis (free)
   - LLM fallback only when confidence/quality is below threshold
2. Add source-level and article-level cache keys to avoid repeated paid generation.
3. Add confidence/quality scoring to decide when LLM is justified.
4. Track per-article generation path (`free` vs `llm`) and cost metadata for reporting.
5. Add admin controls to disable all paid generation instantly.
6. Add adaptive scheduling so source refresh cadence balances cost vs news currency.

Deliverables:

1. Most routine aggregation runs without paid model calls.
2. LLM usage is intentional, explainable, and measurable.

## Phase D: LLM Editorial Orchestrator (Next Priority)

Goals:

1. Make LLM-driven editorial decisions automatic, sparse, and auditable.

Tasks:

1. Implement homepage layout orchestration with hybrid ranking:
   - Importance judged by LLM
   - Recency from deterministic scoring
   - Combined ranking policy for final ordering
2. Trigger layout recomputation when sources are updated, with cooldown/rate limits to optimize cost
   vs freshness.
3. Implement article lifecycle orchestration:
   - Update recent article by default when new source is same story cluster
   - Create a new article only when significance threshold is exceeded
4. Encode significance threshold policy with explicit feature flags and tunable weights.
5. Enforce fully automatic mode (no approval gate) while preserving manual override tools.
6. Persist decision logs per run: prompt version, inputs, output rationale, tokens, cost, and chosen
   action.

Deliverables:

1. Homepage ordering and article create/update behavior run automatically after source refresh.
2. LLM usage remains sparse via gating/cooldowns while retaining editorial quality.
3. All automated decisions are traceable in admin diagnostics.

## Phase E: Lightweight CMS Evolution (Single Author -> Small Team)

Goals:

1. Keep solo publishing friction low now, with a clear future path for contributors.

Tasks:

1. Keep single-admin workflow as default (current mode).
2. Introduce optional draft states and editorial notes for in-progress stories.
3. Add structured attribution and rumour confidence annotations.
4. Prepare permission model extension points for future contributor/editor roles.
5. Add audit-friendly change history for article edits and publish actions.

Deliverables:

1. Solo creator flow remains fast.
2. Collaboration features can be enabled later without reworking core data model.

## Phase F: Audience and Product Fit Feedback Loop

Goals:

1. Learn which formats and topics resonate, then tune the voice and automation accordingly.

Tasks:

1. Add metrics for article engagement by content type (news, rumour, opinion, match reaction).
2. Track publish-source mix (manual vs automated) and relative performance.
3. Add monthly review routine for budget usage vs output quality.
4. Use findings to adjust voice rules, ingestion sources, and LLM fallback thresholds.
5. Add an editorial diagnostics dashboard in admin for ranking runs, LLM timeouts/fallback rate,
   and ingestion freshness/health trends.

Deliverables:

1. A measurable editorial feedback loop tied to cost and quality outcomes.
2. Clear criteria for when to expand beyond single-author mode.

## Phase G: Admin Job Operations Panel

Goals:

1. Give operators complete visibility into active, queued, and completed job behavior.
2. Make each job auditable from input sources to resulting article changes.

Tasks:

1. Add `job_effect_events` persistence on ingestion/editorial workers.
2. Capture source input snapshots (URL, headline, text excerpt) at job execution time.
3. Capture decision outcomes (`created`, `updated`, `amalgamated`, skips) and rationale summary.
4. Capture change details for resulting article mutations (before/after title/body excerpt).
5. Implement admin LiveView page with three job buckets:
   - active,
   - queued,
   - completed/terminal.
6. Add drill-down pane for selected job showing source inputs, decision details, and resulting
   change details.
7. Add pagination and lightweight filters (worker, queue, state, time window).
8. Add tests for state bucketing, outcome rendering, and empty/error states.

Deliverables:

1. Admin can inspect job lifecycle and concrete content outcomes without querying DB manually.
2. Failed and skipped jobs include enough context for remediation.
3. Job-level provenance remains visible after source/article rows evolve.
