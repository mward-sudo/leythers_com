# Data Model and Persistence Specification

## Global DB Conventions

1. Use `:binary_id` primary keys (`uuid`) on all domain tables.
2. Use `timestamps(type: :utc_datetime_usec)` unless table intentionally omits `updated_at`.
3. Add explicit indexes for unique and high-cardinality lookup fields.
4. Add DB-level check constraints for finite status/value enums.

## Table: raw_sources (Ingestion)

Purpose: normalized external source records for pipeline processing.

Columns:

1. `id` uuid pk
2. `title` string not null
3. `url` string not null unique
4. `body_summary` text nullable
5. `origin_provider` string not null
6. `external_published_at` utc_datetime_usec not null
7. `status` string not null default `pending`
8. `last_checked_at` utc_datetime_usec nullable
9. `last_check_status` string nullable
10. `inserted_at`, `updated_at`

Checks:

1. `status in ('pending','processed','ignored')`
2. `last_check_status in ('ok','redirected','broken')` when not null

Indexes:

1. unique index on `url`
2. optional index on `status`
3. optional index on `external_published_at`
4. optional index on `last_check_status`

## Table: permanent_articles (Content)

Purpose: canonical public article storage.

Columns:

1. `id` uuid pk
2. `slug` string not null unique
3. `title` string not null
4. `body` text not null
5. `author_type` string not null default `ai_editor`
6. `raw_content_backup` text nullable
7. `status` string not null default `published`
8. `version` integer not null default 1
9. `inserted_at`, `updated_at`

Checks:

1. `author_type in ('ai_editor','human_admin')`
2. `status in ('draft','published')`
3. `version >= 1`

Indexes:

1. unique index on `slug`
2. optional index on `status`
3. optional index on `author_type`

Behavior rules:

1. AI-generated articles default to immediate `published` status.
2. Editing published articles increments `version`.

## Table: article_sources (Content)

Purpose: attribution join between published articles and raw inputs.

Columns:

1. `id` uuid pk
2. `permanent_article_id` uuid fk not null -> `permanent_articles.id` on delete `:delete_all`
3. `raw_source_id` uuid fk nullable -> `raw_sources.id` on delete `:nilify_all`
4. `inserted_at` utc_datetime_usec not null

Indexes:

1. index on `permanent_article_id`
2. index on `raw_source_id`
3. unique composite index on `(permanent_article_id, raw_source_id)`

Behavior rules:

1. AI-generated articles require at least one linked source record.
2. Manual articles may be published with zero linked sources.

## Table: cost_ledgers (Intelligence)

Purpose: daily token/cost accounting and budget guardrails.

Columns:

1. `id` uuid pk
2. `date` date not null unique
3. `input_tokens` integer not null default 0
4. `output_tokens` integer not null default 0
5. `estimated_cost_gbp` decimal(12, 6) not null default 0.000000
6. `inserted_at`, `updated_at`

Checks:

1. `input_tokens >= 0`
2. `output_tokens >= 0`
3. `estimated_cost_gbp >= 0`

Indexes:

1. unique index on `date`

Operational rules:

1. Default monthly generation cap is `GBP 10.00`.
2. Near-cap threshold is fixed at `80%`.
3. Hard cap blocks generation unless a single-month admin override is active.
4. Override must include an explicit temporary limit and expiry at month end.

## Migration Strategy

Recommended migration order:

1. `raw_sources`
2. `permanent_articles`
3. `article_sources`
4. `cost_ledgers`

Recommended migration file names:

1. `*_create_raw_sources.exs`
2. `*_create_permanent_articles.exs`
3. `*_create_article_sources.exs`
4. `*_create_cost_ledgers.exs`

## Ecto Schema Conventions

All schemas should use:

1. `@primary_key {:id, :binary_id, autogenerate: true}`
2. `@foreign_key_type :binary_id`
3. strict `changeset/2` validation and enum inclusion checks
4. unique constraints matching DB indexes
