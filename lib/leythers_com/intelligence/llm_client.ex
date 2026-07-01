defmodule LeythersCom.Intelligence.LLMClient do
  @moduledoc """
  Configurable LLM client facade used by intelligence/editorial orchestration.

  The configured adapter is responsible for provider-specific request/response
  behavior. Defaults are configured for local Ollama usage.
  """

  @type result :: {:ok, %{text: String.t(), model: String.t()}} | {:error, term()}

  alias __MODULE__.Ollama
  alias LeythersCom.Intelligence.LLMGuard

  @default_rate_limit_enabled false
  @default_rate_limit_key "llm:global"
  @default_rate_limit_scale_ms 1_000
  @default_rate_limit_limit 2
  @default_rate_limit_max_wait_ms 10_000

  @callback generate(String.t(), keyword()) :: result()

  @spec generate(String.t(), keyword()) :: result()
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    with :ok <- wait_for_rate_limit_slot(opts),
         true <- LLMGuard.allow?() do
      do_generate(prompt, opts)
    else
      false -> {:error, :llm_circuit_open}
      {:error, :llm_rate_limited} -> {:error, :llm_rate_limited}
    end
  end

  @spec llm_config() :: keyword()
  def llm_config do
    Application.get_env(:leythers_com, :llm, [])
  end

  defp do_generate(prompt, opts) do
    config = llm_config()
    adapter = config[:adapter] || Ollama
    result = adapter.generate(prompt, Keyword.merge(config, opts))

    report_result(result)
    result
  end

  defp report_result({:ok, _payload}) do
    LLMGuard.report_success()
  end

  defp report_result({:error, reason}) do
    if transient_failure?(reason), do: LLMGuard.report_failure()
  end

  defp report_result(_result), do: :ok

  defp transient_failure?({:request_failed, status, _body}) when is_integer(status) do
    status >= 500 or status == 429
  end

  defp transient_failure?(%Req.TransportError{}), do: true
  defp transient_failure?(:timeout), do: true
  defp transient_failure?(_reason), do: false

  defp wait_for_rate_limit_slot(opts) do
    config = rate_limit_config(opts)

    if Keyword.get(config, :enabled, @default_rate_limit_enabled) do
      wait_started_at_ms = System.monotonic_time(:millisecond)
      do_wait_for_rate_limit_slot(config, wait_started_at_ms)
    else
      :ok
    end
  end

  defp do_wait_for_rate_limit_slot(config, wait_started_at_ms) do
    key = Keyword.get(config, :key, @default_rate_limit_key)
    scale_ms = Keyword.get(config, :scale_ms, @default_rate_limit_scale_ms)
    limit = Keyword.get(config, :limit, @default_rate_limit_limit)

    case Hammer.check_rate(key, scale_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, _limit} ->
        max_wait_ms = Keyword.get(config, :max_wait_ms, @default_rate_limit_max_wait_ms)
        waited_ms = System.monotonic_time(:millisecond) - wait_started_at_ms
        retry_after_ms = retry_after_ms(key, scale_ms, limit)

        if waited_ms + retry_after_ms > max_wait_ms do
          {:error, :llm_rate_limited}
        else
          Process.sleep(max(retry_after_ms, 1))
          do_wait_for_rate_limit_slot(config, wait_started_at_ms)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp retry_after_ms(key, scale_ms, limit) do
    case Hammer.inspect_bucket(key, scale_ms, limit) do
      {:ok, {_count, _remaining, ms_to_next_bucket, _created_at, _updated_at}}
      when is_integer(ms_to_next_bucket) and ms_to_next_bucket > 0 ->
        ms_to_next_bucket

      _ ->
        max(div(scale_ms, 2), 1)
    end
  end

  defp rate_limit_config(opts) do
    app_config = Application.get_env(:leythers_com, :llm_rate_limit, [])
    per_call_override = Keyword.get(opts, :rate_limit, [])
    Keyword.merge(app_config, per_call_override)
  end
end
