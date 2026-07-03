# LeythersCom

To start your Phoenix server:

- Run `mix setup` to install and setup dependencies
- Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Production deployment (Supabase or Neon)

LeythersCom is configured for serverless Postgres deployments where TLS and conservative connection
limits are required.

Required environment variables:

1. `DATABASE_URL`
2. `SECRET_KEY_BASE`
3. `PHX_HOST`

Recommended environment variables:

1. `PORT` (default: `4000`)
2. `PHX_SERVER` (set to `true` for release runtime)
3. `DATABASE_SSL` (default: `true`)
4. `POOL_SIZE` (default: `5`)
5. `DB_USE_UNNAMED_PREPARE` (default: `true`; recommended for transaction-pooled endpoints)
6. `DB_QUEUE_TARGET_MS` (default: `5000`)
7. `DB_QUEUE_INTERVAL_MS` (default: `20000`)
8. `ECTO_IPV6` (set to `true` only when your platform requires IPv6 sockets)
9. `OBAN_QUEUE_DEFAULT` (default: `5`)
10. `OBAN_QUEUE_INGESTION` (default: `2`)
11. `OBAN_QUEUE_INTELLIGENCE` (default: `4`)
12. `OBAN_PRUNER_MAX_AGE_SECONDS` (default: `604800`)
13. `LLM_PROVIDER` (production default: `openrouter`)
14. `OPENROUTER_API_KEY` (required in production when `LLM_PROVIDER=openrouter`)
15. `OPENROUTER_API_ENDPOINT` (default: `https://openrouter.ai/api/v1`)
16. `OPENROUTER_MODEL` (default: `meta-llama/llama-3.1-8b-instruct`)
17. `OPENROUTER_HTTP_REFERER` (recommended for OpenRouter attribution/routing)
18. `OPENROUTER_SITE_NAME` (default: `LeythersCom`)
19. `OLLAMA_API_ENDPOINT` (default: `http://127.0.0.1:11434`)
20. `OLLAMA_MODEL` (default: `llama3.1:8b`)
21. `LLM_TEMPERATURE` (default: `0.4`)
22. `LLM_NUM_PREDICT` (default: `600`)
23. `LLM_TIMEOUT_MS` (default: `30000`)
24. `LLM_RETRY_ENABLED` (default: `true`)
25. `LLM_RETRY_MAX_ATTEMPTS` (default: `3`)
26. `LLM_RETRY_BASE_DELAY_MS` (default: `200`)
27. `LLM_RETRY_MAX_DELAY_MS` (default: `2000`)
28. `LLM_RETRY_JITTER_MS` (default: `100`)

Notes:

1. Keep queue concurrency conservative on serverless Postgres to avoid exhausting connection limits.
2. Tune `POOL_SIZE` together with Oban queue concurrency. Start low, then scale based on observed throughput.
3. Use separate credentials for runtime and migrations when your provider enforces restricted roles.

LLM provider behavior by environment:

1. Production: OpenRouter only. Startup rejects unsupported provider values.
2. Development: can use OpenRouter or local Ollama.
3. Development provider choice is persisted in DB and restored on restart.

Development provider switching (on the fly):

1. Start app in dev, then run:
   - `iex -S mix`
   - `LeythersCom.Intelligence.set_dev_llm_provider(:openrouter)`
   - or `LeythersCom.Intelligence.set_dev_llm_provider(:ollama)`
2. Switch applies immediately to subsequent LLM calls.
3. Preference is persisted in `intelligence_runtime_settings` and survives restarts.

Development provider precedence on startup:

1. If `DEV_LLM_PROVIDER` is set, it wins.
2. Otherwise, app restores persisted `dev_llm_provider` from DB.

Development queue overrides:

1. `DEV_OBAN_QUEUE_INGESTION` (OpenRouter default: `2`, Ollama default: `1`)
2. `DEV_OBAN_QUEUE_INTELLIGENCE` (OpenRouter default: `4`, Ollama default: `1`)

Local Ollama testing:

1. Start Ollama locally.
2. Pull and run the default model:
   - `ollama pull llama3.1:8b`
3. Keep `OLLAMA_API_ENDPOINT=http://127.0.0.1:11434` for cost-free local evaluation.

OpenRouter setup:

1. Set `OPENROUTER_API_KEY` in runtime environment (never commit).
2. Set `OPENROUTER_MODEL` for your chosen model route.
3. Optionally set `OPENROUTER_HTTP_REFERER` and `OPENROUTER_SITE_NAME` for better attribution and policy compliance.

## Editorial decisioning and homepage ordering

The automated editorial path now follows these rules:

1. Similarity decisions are LLM-first using `LeythersCom.Intelligence.DecisionEngine`.
2. If LLM decisioning is unavailable, deterministic fallback is used and provenance metadata is persisted.
3. LLM requests apply per-call exponential backoff with jitter for transient failures.
4. AI draft quality is scored with rubric dimensions (`specificity`, `novelty`, `grounding`, `overall`) and emitted in decision telemetry metadata.
5. Homepage ordering is story-first: recent articles are collapsed to one front article per story before ranking, so duplicate updates do not crowd the page.

Current implementation reference:

1. See [spec/context/current_ingest_editorial_process.md](/Users/michael/Developer/elixir/leythers_com/spec/context/current_ingest_editorial_process.md) for the current ingest and automated editorial pipeline as it exists in code today, including worker handoffs, source-state transitions, draft validation, update-vs-new behavior, and audit surfaces.

Local env file usage:

1. Copy `.env.example` to `.env` for local-only secrets.
2. In development, `.env` is auto-loaded at app boot by `config/runtime.exs`.
3. Already exported shell variables take precedence over `.env` values.
4. `.env` is gitignored.
5. `.env.example` is safe to commit.

## Real Feed Ingestion Testing (Leigh Leopards)

The app is configured with live RSS feeds filtered for Leigh Leopards coverage, including a
Google News RSS query feed for `Leigh Leopards`.

Trigger a live ingestion run manually:

1. `mix run -e "IO.inspect(LeythersCom.Ingestion.ingest_configured_feeds())"`

Inspect ingested sources quickly:

1. `mix run -e "IO.inspect(Enum.take(LeythersCom.Ingestion.list_raw_sources(), 10))"`

Notes:

1. Feed polling is also scheduled via Quantum every 30 minutes.
2. Configured feed filters include keywords `leigh` and `leopards` to reduce off-topic entries.

Health checks:

1. `GET /health` returns `200` with JSON when web and database are healthy.
2. The endpoint returns `503` when the database check fails.
3. In production config, `force_ssl` excludes `/health` so HTTP-only platform probes can still succeed.

Deployment runbook:

1. Build assets and release:
   - `mix assets.deploy`
   - `MIX_ENV=prod mix release`
2. Run migrations before cutting traffic:
   - `MIX_ENV=prod mix ecto.migrate`
3. Start the release with `PHX_SERVER=true`.
4. Verify runtime readiness:
   - `curl -i https://<your-host>/health`
5. Verify authenticated admin access and background processing:
   - log in as admin and open `/admin/overview`
   - confirm telemetry widgets and failed job panel load successfully

## Learn more

- Official website: https://www.phoenixframework.org/
- Guides: https://phoenix.hexdocs.pm/overview.html
- Docs: https://phoenix.hexdocs.pm
- Forum: https://elixirforum.com/c/phoenix-forum
- Source: https://github.com/phoenixframework/phoenix
