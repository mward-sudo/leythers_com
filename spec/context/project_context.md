# Project Context (Compact)

## Objective

Implement Leythers.com as an event-driven content aggregation + generation system with strict budget controls and a manual fast-track publish path.

## Repository Reality

1. OTP app is `:leythers_com`.
2. Use `LeythersCom` namespace in modules unless project rename is explicitly approved.
3. Phoenix project exists; domain contexts for this feature set do not yet exist.

## Required Contexts

1. `LeythersCom.Ingestion`
2. `LeythersCom.Intelligence`
3. `LeythersCom.Content`

## Required Tables

1. `raw_sources`
2. `permanent_articles`
3. `article_sources`
4. `cost_ledgers`

## Hard Rules

1. Binary UUID primary keys.
2. DB constraints for enum-like statuses.
3. Manual fast-track bypasses Oban and LLM calls.
4. Generation path must enforce monthly spend cap (`GBP 10.00`) with near-cap warnings at `80%`.
5. Hard cap blocks generation unless a single-month admin override is active.
6. Maintain source attribution links.
7. AI-generated articles publish immediately and require at least one source link.
8. Manual articles may be published without source links.
9. Preserve first-seen source metadata; only update URLs based on link-health checks/redirect handling.

## Step-1 Implementation Targets

Migrations in `priv/repo/migrations` for all four tables and schema modules in:

1. `lib/leythers_com/ingestion/raw_source.ex`
2. `lib/leythers_com/content/permanent_article.ex`
3. `lib/leythers_com/content/article_source.ex`
4. `lib/leythers_com/intelligence/cost_ledger.ex`

## Key Risks

1. Cost pressure from aggressive ingestion cadence.
2. Link-health update policy causing unexpected source URL churn.
3. Complexity creep from article versioning and override controls.
