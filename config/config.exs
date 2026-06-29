# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :leythers_com, :scopes,
  user: [
    default: true,
    module: LeythersCom.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: LeythersCom.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :leythers_com,
  ecto_repos: [LeythersCom.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :leythers_com, LeythersComWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LeythersComWeb.ErrorHTML, json: LeythersComWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LeythersCom.PubSub,
  live_view: [signing_salt: "7abP/w7a"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :leythers_com, LeythersCom.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  leythers_com: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.1",
  leythers_com: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Configure intelligence budget guardrails
config :leythers_com, :intelligence_budget, monthly_cap_gbp: "10.00"

# Configure deterministic editorial voice profile
config :leythers_com, :voice_profile,
  rumour_title_prefix: "Rumour:",
  rumour_notice: "Rumour mill warning: treat this as chatter until confirmed.",
  fan_signoff: "Terrace verdict: proper Leythers chaos, and we love it."

# Configure LLM provider defaults for local low-cost testing
config :leythers_com, :llm,
  adapter: LeythersCom.Intelligence.LLMClient.Ollama,
  endpoint: "http://127.0.0.1:11434",
  model: "qwen3:1.7b",
  temperature: 0.4,
  num_predict: 600,
  timeout_ms: 30_000

config :leythers_com, :homepage_ranking,
  llm_enabled: true,
  llm_candidate_limit: 1,
  llm_cooldown_seconds: 1_800,
  llm_timeout_ms: 2_500,
  recency_weight: 0.45,
  importance_weight: 0.55,
  max_age_hours: 72

config :leythers_com, :editorial_orchestration,
  source_limit: 20,
  homepage_size: 12,
  refresh_cooldown_seconds: 300,
  async_source_refresh: true,
  prompt_version: "homepage_ranker_v1"

config :leythers_com, :intelligence_generation,
  auto_generation_enabled: true,
  source_batch_size: 20,
  max_batches_per_run: 20,
  significance_threshold: 70,
  prompt_version: "source_editorial_v1",
  llm_draft_enabled: true,
  llm_cost_per_1k_tokens_gbp: "0.000000"

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Oban
config :leythers_com, Oban,
  repo: LeythersCom.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [default: 10, ingestion: 5, intelligence: 2]

# Configure real web feeds for ingestion
config :leythers_com, :ingestion_feeds, [
  %{
    url: "https://news.google.com/rss/search?q=Leigh+Leopards&hl=en-GB&gl=GB&ceid=GB:en",
    origin_provider: "google_news_leigh_leopards",
    include_keywords: ["leigh", "leopards"]
  },
  %{
    url: "https://www.bbc.co.uk/sport/rugby-league/rss.xml",
    origin_provider: "bbc_rugby_league",
    include_keywords: ["leigh", "leopards"]
  },
  %{
    url: "https://www.seriousaboutrl.com/feed/",
    origin_provider: "serious_about_rl",
    include_keywords: ["leigh", "leopards"]
  }
]

config :leythers_com, :ingestion_monitoring,
  stale_after_hours: 6,
  enqueue_dedupe_seconds: 900,
  retry_base_seconds: 60,
  retry_max_seconds: 1800,
  retry_multipliers: %{
    "google_news_leigh_leopards" => 2.0
  }

# Configure Quantum scheduler
config :leythers_com, LeythersCom.Scheduler,
  jobs: [
    {"@daily", {LeythersCom.Ingestion.SourceLinkHealthChecker, :check_all_raw_sources, []}},
    {"*/30 * * * *", {LeythersCom.Ingestion, :ingest_configured_feeds, []}},
    {"@hourly", {LeythersCom.Ingestion, :refresh_stale_feeds, []}},
    {"*/10 * * * *", {LeythersCom.Intelligence.SourceEditorialWorker, :enqueue, [%{}]}}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
