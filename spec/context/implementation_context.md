Act as an elite Elixir/Phoenix staff engineer. I am building an ultra-low-cost, high-performance content aggregator and generator site for Leigh Leopards rugby league fans called "Leythers.com".

Our stack consists of:

- Elixir 1.18+
- Erlang/OTP 27+
- Phoenix 1.8+ (LiveView + Controllers)
- Serverless PostgreSQL (Supabase/Neon) using binary UUIDs for primary keys
- Oban Community Edition for background queues
- Quantum for cron jobs
- Req + Floki for lightweight concurrent scraping
- OpenAI API - OpenRouter (meta-llama/llama-3.1-8b-instruct) with a strict monthly cost tracker

Repository alignment notes:

- Existing OTP app is `:leythers_com`.
- Use `LeythersCom.*` module namespaces and paths unless a full rename is explicitly requested.

SYSTEM SPECIFICATION DOCUMENT

SECTION 1 ARCHITECTURAL PHILOSOPHY AND CONTEXT BOUNDARY
The application uses an event-driven, asynchronous data pipeline rather than on-demand processing. It treats automated content generation as a series of pipeline stages managed by internal supervision trees, transactional background jobs via Oban, and state tracking.

To support manual content entry, the system features a Fast-Track Transaction Layer that completely bypasses background workers, allowing the human author to publish instantly.

The system isolates third-party API adapters, content ingestion parsers, and business core domains using three discrete Elixir contexts:

1. Ingestion Context
2. Intelligence Context
3. Content Context

Flow Details:

- External providers (RSS/HTML) -> Ingestion -> Processing/Intelligence -> Content publishing.
- Human Admin Input LiveView -> Fast-Track transaction -> Content publishing.

SECTION 2 INFRASTRUCTURE AND COST GUARDRAILS STACK
The tech stack runs strictly within a GBP 10.00/month maximum operational envelope.

- Database: Serverless PostgreSQL via Supabase or Neon.
- Job Queue: Oban CE (Postgres-backed).

SECTION 3 DATA SCHEMA AND CORE DOMAIN MODELS ECTO

Relationships:

- `raw_sources` has many `article_sources`
- `permanent_articles` has many `article_sources`
- `article_sources` belongs to `raw_sources` and `permanent_articles`

  3.1 Ingestion: `raw_sources`

- `id`: binary_id primary key
- `title`: string required
- `url`: string required unique
- `body_summary`: text optional
- `origin_provider`: string required (e.g. `bbc_sport`, `leigh_journal`, `manual_admin`)
- `external_published_at`: utc_datetime required
- `status`: string default `pending` values `pending|processed|ignored`
- timestamps

  3.2 Content: `permanent_articles`

- `id`: binary_id primary key
- `slug`: string required unique
- `title`: string required
- `body`: text required (Markdown)
- `author_type`: string default `ai_editor` values `ai_editor|human_admin`
- `raw_content_backup`: text optional
- `status`: string default `published` values `draft|published`
- `version`: integer default `1`
- timestamps

  3.2 Content: `article_sources`

- `id`: binary_id primary key
- `permanent_article_id`: FK -> `permanent_articles` on_delete `:delete_all`
- `raw_source_id`: FK -> `raw_sources` on_delete `:nilify_all`
- `inserted_at`: utc_datetime

  3.3 Intelligence: `cost_ledgers`

- `id`: binary_id primary key
- `date`: date unique
- `input_tokens`: integer default 0
- `output_tokens`: integer default 0
- `estimated_cost_gbp`: decimal default 0.0000

SECTION 4 MANUAL FAST-TRACK PIPELINE MECHANICS
When the admin publishes an original article via the dashboard:

- The payload bypasses Oban and OpenAI.
- Title is slugified.
- Insert directly into `permanent_articles` with `author_type=human_admin` and `status=published`.
- Selected source links are inserted into `article_sources`.

DECISIONS ALREADY MADE (TREAT AS REQUIREMENTS)

- Keep repository namespace as `LeythersCom`.
- Monthly cap is `GBP 10.00`.
- Near-cap warning threshold is `80%`.
- Generation is hard-blocked at cap, with a single-month admin override to a temporary higher limit.
- AI-generated articles publish immediately.
- Published article edits should increment `version`.
- URL dedupe should preserve first-seen metadata.
- Canonicalization removes known tracking query parameters.
- If source links become invalid or permanently redirected, update canonical source URL and record health state.
- AI-generated articles require at least one source link.
- Manual articles may publish with zero source links.
- Ingestion cadence and worker concurrency should start conservatively and be tuned by observed cost/load telemetry.

YOUR TASK: EXECUTE STEP 1
Based on Section 3 and Section 4, generate code for:

1. Exact Ecto migration files in `priv/repo/migrations/` to build:
   - `raw_sources`
   - `permanent_articles`
   - `article_sources`
   - `cost_ledgers`

Requirements:

- binary UUID PKs
- proper unique indexes
- explicit FK `on_delete` behavior
- DB check constraints for enum-like fields
- support link-health fields/policy needed for broken/redirected sources

2. Corresponding Ecto schema modules:
   - `lib/leythers_com/ingestion/raw_source.ex`
   - `lib/leythers_com/content/permanent_article.ex`
   - `lib/leythers_com/content/article_source.ex`
   - `lib/leythers_com/intelligence/cost_ledger.ex`

Requirements:

- production-ready changesets
- validation and constraint mapping
- `@primary_key` and `@foreign_key_type` set for binary IDs
- enforce AI source-link requirement in content-layer publishing API
