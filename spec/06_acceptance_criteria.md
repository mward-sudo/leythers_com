# Acceptance Criteria

## Phase 0

1. App compiles with target dependency set.
2. Oban and Quantum start under supervision.
3. Precommit alias remains green.

## Phase 1

1. All four tables exist with expected constraints and indexes.
2. Foreign key delete behaviors match spec.
3. Schema changesets reject invalid enum values.
4. Unique constraints surface user-friendly changeset errors.
5. `raw_sources` supports health-check state fields and constraints.

## Phase 2

1. Manual admin submission publishes immediately.
2. Slug collision handling is deterministic.
3. Selected source links are attached atomically.
4. Rollback occurs if any link insert fails.
5. Manual publish is valid with zero source links.

## Phase 3

1. Scheduled ingestion runs at configured intervals.
2. Duplicate URLs do not create duplicate `raw_sources` records.
3. Failures retry according to worker policy.
4. Canonicalization strips tracking query params.
5. First-seen source metadata is preserved by default.
6. Source-link health checks mark rows as ok/redirected/broken.

## Phase 4

1. Generation is blocked when monthly budget is exceeded.
2. Cost ledger updates daily and remains non-negative.
3. Near-cap warnings trigger at 80% of monthly cap.
4. Single-month admin override can temporarily raise cap.
5. AI-generated articles publish immediately.
6. Generated articles include provenance links.
7. AI-generated publications require at least one source link.

## Cross-Cutting

1. Tests cover normal path, validation failures, and DB constraints.
2. Telemetry events emitted for major pipeline transitions.
3. Documentation reflects actual module names (`LeythersCom.*`).
4. Published article edits increment `version`.

## Editorial Orchestration

1. Homepage layout uses a hybrid ranking model combining LLM-judged importance and deterministic
   recency scoring.
2. Homepage layout recalculation is triggered by source updates, with scheduling/rate-limits that
   balance cost and freshness.
3. Rumours are clearly labeled in UI and in generated article content.
4. Automated article lifecycle defaults to updating a recent matching story, and creates a new
   article only when significance threshold is exceeded.
5. Automated editorial mode can run fully without human approval while preserving manual override.
6. LLM invocation controls (budget gates, caching, and fallback behavior) keep spend within monthly
   cap and reduce unnecessary calls.
7. Each LLM decision persists audit metadata: prompt/template version, source inputs,
   rationale/decision summary, token counts, and estimated cost.
8. Voice consistency checks enforce rough fan tone with irreverent humour while validating core
   factual grounding to cited sources.

## Admin Job Operations Panel

1. Admin page shows three lifecycle groups: active (`executing`), queued
   (`available`/`scheduled`/`retryable`), and completed/terminal
   (`completed`/`discarded`/`cancelled`).
2. Every completed or terminal ingestion/editorial job has at least one persisted outcome record
   suitable for diagnostics rendering.
3. Job detail view includes source input details used by execution:
   - source URL,
   - source headline,
   - source text excerpt/summary.
4. Job detail view includes decision details for create/update/amalgamate/skip outcomes.
5. Job detail view includes resulting change details:
   - target article identifier,
   - before/after excerpt for updated/amalgamated content.
6. Job detail rendering remains available even if linked source/article rows are later modified or
   deleted.
7. Page supports pagination and filtering by queue, worker, and state without timeouts under normal
   expected load.
