# Product Scope: Leythers.com

## Vision

Build an ultra-low-cost, high-performance Leigh Leopards fan content platform that:

- aggregates rugby league source material,
- uses LLM judgment sparingly for high-value editorial decisions,
- generates and updates publishable headline/summary/full-article packages with a distinct fan
   voice,
- supports immediate human-authored publishing,
- stays inside strict monthly spend limits.

## Primary Objectives

1. Use LLM decisions where they provide clear editorial value (home layout, article create/update),
   while minimizing paid-token usage.
2. Publish reliably from both AI-assisted and manual authoring paths.
3. Preserve source attribution and decision auditability for trust.
4. Enforce predictable operating costs.
5. Keep architecture simple enough for a small team.
6. Provide an admin operations panel that exposes active, queued, and completed jobs with
   human-readable outcome details.

## Explicit Constraints

1. Monthly operating budget target: <= GBP 10.00.
2. PostgreSQL is the single persistence/queue dependency.
3. Binary UUID primary keys across domain tables.
4. Background processing via Oban CE.
5. Scheduled jobs via Quantum.

## Non-Goals (Initial Release)

1. User accounts and role hierarchy beyond a simple admin surface.
2. Multi-tenant organization support.
3. Rich CMS workflow (approval chains, editorial roles).
4. Real-time social graph ingestion.

## Invariants

1. Public article slugs must be unique and stable once published.
2. Every AI-generated article should preserve source linkage where applicable.
3. Manual fast-track publishing must not require background jobs.
4. Cost ledger writes must be idempotent per day bucket.
5. Homepage ordering must use a hybrid of importance and recency.
6. Rumours must be explicitly labeled and handled as rumours in generated content.
7. Automated ingestion-to-publishing runs are fully automatic by default.
8. LLM decisions must be auditable (prompt version, inputs, rationale, token/cost metadata).
9. Generated editorial output must include a headline, a summary teaser, and full article body.
10. Headlines must lead with a clear Leigh Leopards angle, stay interesting without major spoilers,
   and avoid misleading clickbait framing.
11. Summary teasers must be accurate, concise, and plain text only (no markup, links, or embedded
   formatting).
12. Full article voice should read like a fan journalist: colloquial Leigh tone, light-hearted
   rugby-league humour, and British sports-magazine flavor inspired by old-school style writing.
13. Running jokes should remain occasional and restrained so clarity and factual grounding remain
   primary.
14. Every ingestion/editorial job must be traceable from execution state to concrete content outcome
   (source inputs, decision taken, and resulting article changes).
