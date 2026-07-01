import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/leythers_com start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :leythers_com, LeythersComWeb.Endpoint, server: true
end

config :leythers_com, LeythersComWeb.Endpoint,
  http: [port: System.get_env("PORT", "4000") |> String.to_integer()]

if config_env() == :prod do
  env_bool = fn key, default ->
    case System.get_env(key) do
      nil -> default
      value when value in ["1", "true", "TRUE", "yes", "YES"] -> true
      _value -> false
    end
  end

  env_int = fn key, default ->
    case System.get_env(key) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  env_float = fn key, default ->
    case System.get_env(key) do
      nil -> default
      value -> String.to_float(value)
    end
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  database_ssl = env_bool.("DATABASE_SSL", true)
  maybe_ipv6 = if env_bool.("ECTO_IPV6", false), do: [:inet6], else: []
  pool_size = env_int.("POOL_SIZE", 5)
  queue_target = env_int.("DB_QUEUE_TARGET_MS", 5000)
  queue_interval = env_int.("DB_QUEUE_INTERVAL_MS", 20_000)
  use_unnamed_prepare = env_bool.("DB_USE_UNNAMED_PREPARE", true)

  config :leythers_com, LeythersCom.Repo,
    ssl: database_ssl,
    url: database_url,
    pool_size: pool_size,
    queue_target: queue_target,
    queue_interval: queue_interval,
    prepare: if(use_unnamed_prepare, do: :unnamed, else: :named),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  config :leythers_com, Oban,
    repo: LeythersCom.Repo,
    plugins: [
      {Oban.Plugins.Pruner, max_age: env_int.("OBAN_PRUNER_MAX_AGE_SECONDS", 60 * 60 * 24 * 7)},
      {
        Oban.Plugins.Lifeline,
        rescue_after: env_int.("OBAN_LIFELINE_RESCUE_AFTER_MS", :timer.minutes(30))
      }
    ],
    queues: [
      default: env_int.("OBAN_QUEUE_DEFAULT", 5),
      ingestion: env_int.("OBAN_QUEUE_INGESTION", 2),
      intelligence: env_int.("OBAN_QUEUE_INTELLIGENCE", 1)
    ]

  config :leythers_com, :llm,
    adapter: LeythersCom.Intelligence.LLMClient.Ollama,
    endpoint: System.get_env("LLM_API_ENDPOINT") || "http://127.0.0.1:11434",
    model: System.get_env("LLM_MODEL") || "qwen3:1.7b",
    temperature: env_float.("LLM_TEMPERATURE", 0.4),
    num_predict: env_int.("LLM_NUM_PREDICT", 600),
    timeout_ms: env_int.("LLM_TIMEOUT_MS", 30_000),
    log_requests: env_bool.("LLM_LOG_REQUESTS", false)

  config :leythers_com, :llm_guard,
    failure_threshold: env_int.("LLM_GUARD_FAILURE_THRESHOLD", 4),
    open_cooldown_ms: env_int.("LLM_GUARD_OPEN_COOLDOWN_MS", 30_000)

  config :leythers_com, :llm_rate_limit,
    enabled: env_bool.("LLM_RATE_LIMIT_ENABLED", true),
    key: System.get_env("LLM_RATE_LIMIT_KEY") || "llm:global",
    scale_ms: env_int.("LLM_RATE_LIMIT_SCALE_MS", 1_000),
    limit: env_int.("LLM_RATE_LIMIT_LIMIT", 2),
    max_wait_ms: env_int.("LLM_RATE_LIMIT_MAX_WAIT_MS", 10_000)

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :leythers_com, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :leythers_com, LeythersComWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :leythers_com, LeythersComWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :leythers_com, LeythersComWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :leythers_com, LeythersCom.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
