# Architecture Specification

## Target Runtime Stack

- Elixir 1.18+
- Erlang/OTP 27+
- Phoenix 1.8+ (LiveView + Controllers)
- PostgreSQL (Supabase/Neon)
- Oban Community Edition
- Quantum
- Req + Floki

## Context Boundaries

The application is split into three business contexts plus cross-cutting infra concerns.

### 1) Ingestion Context

Responsibilities:

- fetch RSS/HTML/provider payloads,
- parse into normalized source records,
- deduplicate by canonical URL,
- stage data for downstream processing.

Owns:

- `raw_sources`

### 2) Intelligence Context

Responsibilities:

- invoke LLM APIs,
- estimate token usage/cost,
- enforce monthly budget policy,
- write daily cost ledger entries.

Owns:

- `cost_ledgers`

### 3) Content Context

Responsibilities:

- store canonical published content,
- manage immutable slug-based article identity,
- maintain source provenance links,
- support manual publishing UI.

Owns:

- `permanent_articles`
- `article_sources`

### 4) Admin Operations Surface

Responsibilities:

- expose active, queued, completed, and failed background jobs,
- render per-job execution details and resulting content changes,
- provide operator-grade diagnostics for ingestion/editorial outcomes.

Reads/depends on:

- `oban_jobs` (job lifecycle state)
- job effect/provenance records (see Data Model)
- source/article/decision tables for contextual drill-down.

## Flow Topology

### Asynchronous ingestion/generation path

1. Scheduler triggers fetch jobs.
2. Ingestion workers fetch and parse provider data.
3. New/updated source records are inserted/upserted.
4. Processing jobs create generated content drafts/publications.
5. Source attribution links are written.

### Manual fast-track path

1. Admin submits article via LiveView.
2. Application validates and slugifies title synchronously.
3. `permanent_articles` row is inserted immediately.
4. Optional source references are linked in `article_sources`.

No Oban or LLM call is required for this fast-track route.

### Admin operations diagnostics path

1. Admin opens operations panel.
2. UI queries job lifecycle state from Oban-backed data.
3. UI joins job state with job-effect records and linked domain entities.
4. Admin can inspect:
   - source inputs (URL, headline, source summary/body excerpt),
   - editorial decision outcome (create/update/amalgamate/skip),
   - resulting article changes and linkage updates.

## Supervision & Runtime Components

Expected application children:

1. `LeythersCom.Repo`
2. `LeythersComWeb.Telemetry`
3. `Phoenix.PubSub`
4. `Finch` via Req
5. `Oban`
6. `Quantum` scheduler
7. `LeythersComWeb.Endpoint`

## Design Decisions

1. Keep providers and parsers behind explicit behavior contracts.
2. Prefer idempotent jobs and deterministic dedupe keys.
3. Record source-provenance links for all publishable artifacts.
4. Use DB constraints to enforce domain safety before app-level checks.
5. Persist deterministic job-effect summaries so operations UI remains stable even when source/article
   rows evolve after job completion.
