# Pipeline and Job Processing Specification

## Pipeline A: Ingestion -> Processing -> Publishing

### Stage A1: Fetch

1. Quantum schedules provider fetch jobs.
2. Oban worker executes fetch with Req.
3. Response parsed via provider-specific parser module.

Failure policy:

1. Retry transient network failures.
2. Mark permanent parser incompatibilities for manual review.

### Stage A2: Normalize & Deduplicate

1. Canonicalize URLs.
2. Strip known tracking query keys during canonicalization (for example: `utm_*`, `fbclid`, `gclid`).
3. Upsert/insert into `raw_sources` by unique URL.
4. Preserve first-seen title/summary/provider metadata by default.
5. Run periodic source-link health checks; when links are broken or permanently redirected, update canonical URLs and health status fields.

### Stage A3: Generate/Transform

1. Enqueue generation job for eligible sources.
2. Check budget gate before API invocation.
3. Invoke LLM only when budget allows.
4. Persist token/cost deltas into `cost_ledgers`.

### Stage A4: Publish & Attribute

1. Create `permanent_articles` with AI author type.
2. Require at least one source row and link all used source rows via `article_sources`.
3. Update `raw_sources.status` to `processed`.

## Pipeline B: Manual Fast-Track

### Step B1: Validate Input

1. Validate title/body required fields.
2. Validate optional source IDs existence.

### Step B2: Synchronous Publish

1. Generate slug from title.
2. Insert directly into `permanent_articles` with:
   - `author_type = human_admin`
   - `status = published`
   - `version = 1`
3. Insert `article_sources` links for selected references.

### Step B3: Return Published Resource

1. Render success response with permalink.
2. Do not enqueue background jobs for this flow.

## Budget Guardrail Rules

1. Maintain a monthly GBP cap value in configuration.
2. Compute month-to-date sum from `cost_ledgers` before generation.
3. Emit near-cap warning events when month-to-date spend reaches `80%` of cap.
4. Skip generation when cap is exceeded and emit telemetry/event.
5. Allow a single-month admin override with an explicit temporary limit.
6. Continue ingestion even when generation is paused.

## Throughput Defaults (Initial)

1. Start with conservative cadence: fetch each provider every `30 minutes`.
2. Lower to `60 minutes` automatically when near-cap.
3. Set initial ingestion worker concurrency to `3` and generation worker concurrency to `1`.
4. Re-tune cadence and concurrency after two weeks using telemetry and DB load metrics.

## Observability

1. Emit telemetry events per pipeline stage.
2. Track counts: fetched, deduped, generated, published, failed.
3. Track budget state transitions: below_cap, near_cap, over_cap.
4. Track source-link health transitions: ok, redirected, broken.
