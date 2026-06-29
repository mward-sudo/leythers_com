# LeythersCom

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

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
11. `OBAN_QUEUE_INTELLIGENCE` (default: `1`)
12. `OBAN_PRUNER_MAX_AGE_SECONDS` (default: `604800`)

Notes:

1. Keep queue concurrency conservative on serverless Postgres to avoid exhausting connection limits.
2. Tune `POOL_SIZE` together with Oban queue concurrency. Start low, then scale based on observed throughput.
3. Use separate credentials for runtime and migrations when your provider enforces restricted roles.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
