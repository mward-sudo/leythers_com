defmodule LeythersCom.Intelligence.LLMClient do
  @moduledoc """
  Configurable LLM client facade used by intelligence/editorial orchestration.

  The configured adapter is responsible for provider-specific request/response
  behavior. Defaults are configured for local Ollama usage.
  """

  @type result :: {:ok, %{text: String.t(), model: String.t()}} | {:error, term()}

  alias __MODULE__.Ollama
  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.LLMGuard
  alias LeythersCom.Intelligence.LLMProvider

  @default_rate_limit_enabled false
  @default_rate_limit_key "llm:global"
  @default_rate_limit_scale_ms 1_000
  @default_rate_limit_limit 2
  @default_rate_limit_max_wait_ms 10_000
  @default_retry_enabled true
  @default_retry_max_attempts 3
  @default_retry_base_delay_ms 200
  @default_retry_max_delay_ms 2_000
  @default_retry_jitter_ms 100

  @callback generate(String.t(), keyword()) :: result()

  @spec generate(String.t(), keyword()) :: result()
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    with :ok <- wait_for_rate_limit_slot(opts),
         true <- LLMGuard.allow?() do
      do_generate(prompt, opts)
    else
      false ->
        result = {:error, :llm_circuit_open}
        maybe_log_interaction(prompt, opts, llm_config(), result, 1)
        result

      {:error, :llm_rate_limited} ->
        result = {:error, :llm_rate_limited}
        maybe_log_interaction(prompt, opts, llm_config(), result, 1)
        result
    end
  end

  @spec llm_config() :: keyword()
  def llm_config do
    LLMProvider.llm_config()
  end

  defp do_generate(prompt, opts) do
    config = Keyword.get(opts, :llm_config, llm_config())
    adapter = config[:adapter] || Ollama

    adapter_opts =
      config
      |> Keyword.merge(Keyword.drop(opts, [:llm_config, :log_context, :log_metadata]))

    retry_config = retry_config(opts)

    if Keyword.get(retry_config, :enabled, @default_retry_enabled) do
      generate_with_retries(adapter, prompt, adapter_opts, opts, retry_config)
    else
      result = logged_adapter_generate(adapter, prompt, adapter_opts, opts, 1)
      report_result(result)
      result
    end
  end

  defp generate_with_retries(adapter, prompt, adapter_opts, opts, retry_config) do
    retry_state = %{
      max_attempts: max(Keyword.get(retry_config, :max_attempts, @default_retry_max_attempts), 1),
      base_delay_ms:
        max(Keyword.get(retry_config, :base_delay_ms, @default_retry_base_delay_ms), 1),
      max_delay_ms: max(Keyword.get(retry_config, :max_delay_ms, @default_retry_max_delay_ms), 1),
      jitter_ms: max(Keyword.get(retry_config, :jitter_ms, @default_retry_jitter_ms), 0)
    }

    do_generate_with_retries(
      adapter,
      prompt,
      adapter_opts,
      opts,
      retry_state,
      1
    )
  end

  defp do_generate_with_retries(
         adapter,
         prompt,
         adapter_opts,
         opts,
         retry_state,
         attempt
       ) do
    result = logged_adapter_generate(adapter, prompt, adapter_opts, opts, attempt)
    report_result(result)

    if retryable_result?(result) and attempt < retry_state.max_attempts do
      Process.sleep(
        backoff_delay_ms(
          attempt,
          retry_state.base_delay_ms,
          retry_state.max_delay_ms,
          retry_state.jitter_ms
        )
      )

      do_generate_with_retries(
        adapter,
        prompt,
        adapter_opts,
        opts,
        retry_state,
        attempt + 1
      )
    else
      result
    end
  end

  defp logged_adapter_generate(adapter, prompt, adapter_opts, opts, attempt) do
    result = adapter.generate(prompt, adapter_opts)
    maybe_log_interaction(prompt, opts, adapter_opts, result, attempt, adapter)
    result
  end

  defp maybe_log_interaction(prompt, opts, adapter_opts, result, attempt, adapter \\ nil) do
    metadata =
      opts
      |> Keyword.get(:log_metadata, %{})
      |> normalize_log_value()
      |> ensure_map()
      |> Map.merge(%{
        "timeout_ms" => normalize_log_value(adapter_opts[:timeout_ms]),
        "temperature" => normalize_log_value(adapter_opts[:temperature]),
        "num_predict" => normalize_log_value(adapter_opts[:num_predict])
      })

    attrs = %{
      adapter: adapter_name(adapter || adapter_opts[:adapter] || Ollama),
      model: normalize_model(result, adapter_opts),
      status: log_status(result),
      attempt: attempt,
      prompt: prompt,
      context: opts |> Keyword.get(:log_context, %{}) |> normalize_log_value() |> ensure_map(),
      response_text: normalize_response_text(result),
      error_summary: normalize_error_summary(result),
      metadata: metadata
    }

    _ = Intelligence.create_llm_interaction_log(attrs)
    :ok
  rescue
    _ -> :ok
  end

  defp log_status({:ok, _payload}), do: "ok"
  defp log_status(_result), do: "error"

  defp normalize_model({:ok, %{model: model}}, _adapter_opts) when is_binary(model), do: model
  defp normalize_model(_result, adapter_opts), do: normalize_log_value(adapter_opts[:model])

  defp normalize_response_text({:ok, %{text: text}}) when is_binary(text), do: text

  defp normalize_response_text({:ok, payload}),
    do: inspect(payload, pretty: true, limit: :infinity)

  defp normalize_response_text(_result), do: nil

  defp normalize_error_summary({:error, reason}),
    do: inspect(reason, pretty: true, limit: :infinity)

  defp normalize_error_summary(_result), do: nil

  defp adapter_name(module) when is_atom(module), do: Atom.to_string(module)
  defp adapter_name(other), do: inspect(other)

  defp ensure_map(%{} = map), do: map
  defp ensure_map(other), do: %{"value" => other}

  defp normalize_log_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp normalize_log_value(nil), do: nil
  defp normalize_log_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_log_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_log_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_log_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_log_value(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize_log_value(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.into(%{}, fn {key, nested_value} ->
        {to_string(key), normalize_log_value(nested_value)}
      end)
    else
      Enum.map(value, &normalize_log_value/1)
    end
  end

  defp normalize_log_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize_log_value/1)
  end

  defp normalize_log_value(%_{} = value) do
    value
    |> Map.from_struct()
    |> Map.new(fn {key, nested_value} -> {to_string(key), normalize_log_value(nested_value)} end)
  end

  defp normalize_log_value(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), normalize_log_value(nested_value)}
    end)
  end

  defp normalize_log_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp retryable_result?({:error, reason}), do: transient_failure?(reason)
  defp retryable_result?(_result), do: false

  defp backoff_delay_ms(attempt, base_delay_ms, max_delay_ms, jitter_ms) do
    raw_delay = base_delay_ms * trunc(:math.pow(2, attempt - 1))
    bounded_delay = min(raw_delay, max_delay_ms)
    jitter = if jitter_ms == 0, do: 0, else: :rand.uniform(jitter_ms) - 1

    bounded_delay + jitter
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
  defp transient_failure?(:missing_openrouter_api_key), do: false
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

  defp retry_config(opts) do
    app_config = Application.get_env(:leythers_com, :llm_retry, [])
    per_call_override = Keyword.get(opts, :retry, [])
    Keyword.merge(app_config, per_call_override)
  end
end
