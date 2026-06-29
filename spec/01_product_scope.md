# Product Scope: Leythers.com

## Vision

Build an ultra-low-cost, high-performance Leigh Leopards fan content platform that:

- aggregates rugby league source material,
- generates publishable summaries/articles,
- supports immediate human-authored publishing,
- stays inside strict monthly spend limits.

## Primary Objectives

1. Publish reliably from both AI-assisted and manual authoring paths.
2. Preserve source attribution for trust and auditability.
3. Enforce predictable operating costs.
4. Keep architecture simple enough for a small team.

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
