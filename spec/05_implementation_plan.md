# Implementation Plan

## Phase 0: Foundation and Dependencies

Goals:

1. Align runtime and dependencies with target stack.
2. Prepare app supervision for queue/scheduler.

Tasks:

1. Upgrade Elixir/OTP runtime target in project docs/tooling.
2. Add dependencies: Oban, Quantum, Floki.
3. Configure Oban + Quantum in config files.
4. Wire Oban and Quantum children in application supervision tree.

Deliverables:

1. Build passes.
2. App boots with all required children.

## Phase 1: Data Layer (Step 1 from Prompt)

Goals:

1. Establish core tables and Ecto schemas.

Tasks:

1. Generate and implement migrations for:
   - `raw_sources`
   - `permanent_articles`
   - `article_sources`
   - `cost_ledgers`
2. Implement schemas in:
   - `lib/leythers_com/ingestion/raw_source.ex`
   - `lib/leythers_com/content/permanent_article.ex`
   - `lib/leythers_com/content/article_source.ex`
   - `lib/leythers_com/intelligence/cost_ledger.ex`
3. Add changesets with constraints and validations.
4. Add context-level CRUD/upsert entry points.

Deliverables:

1. `mix ecto.migrate` succeeds.
2. Changesets enforce domain rules.

## Phase 2: Manual Fast-Track Publish

Goals:

1. Provide immediate human publishing flow.

Tasks:

1. Build admin LiveView form.
2. Add slug generation service.
3. Insert article and optional source links synchronously in a transaction.
4. Ensure manual path allows publish with zero source links.
5. Add tests for success/failure/constraint paths.

Deliverables:

1. Manual publish path works without Oban/LLM dependency.

## Phase 3: Ingestion Pipeline

Goals:

1. Enable scheduled source ingestion and dedupe.

Tasks:

1. Define provider behaviors and adapters.
2. Implement Req + Floki parsing workers.
3. Schedule jobs with Quantum.
4. Persist `raw_sources` with first-seen-preserving dedupe policy.
5. Canonicalize URLs and strip tracking query parameters.
6. Add periodic source-link health checker and URL update policy for broken/redirected links.

Deliverables:

1. Repeatable ingestion with idempotent outcomes.

## Phase 4: Intelligence and Publishing Automation

Goals:

1. Add generation with budget enforcement.

Tasks:

1. Implement LLM client abstraction.
2. Add monthly cap checker against `cost_ledgers`.
3. Emit near-cap warnings at 80% of monthly cap.
4. Implement single-month admin override with explicit temporary cap.
5. Generate article body/title and publish immediately (`published`).
6. Enforce at least one linked source for AI-generated publications.
7. Track daily token/cost rollups.

Deliverables:

1. Generation auto-publishing works while under budget.
2. Over-budget mode blocks generation only.

## Phase 5: Hardening

Goals:

1. Improve reliability and operability.

Tasks:

1. Add telemetry dashboards and alerts.
2. Add dead-letter/retry review tooling.
3. Add admin views for source/article provenance and cost history.
4. Finalize deployment settings for Supabase/Neon constraints.
5. Add article edit workflow that increments `version` on each published update.
