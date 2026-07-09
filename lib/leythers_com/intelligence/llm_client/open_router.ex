defmodule LeythersCom.Intelligence.LLMClient.OpenRouter do
  @moduledoc """
  OpenRouter-backed LLM adapter.

  Uses OpenRouter's OpenAI-compatible chat completions endpoint.
  """

  require Logger

  @behaviour LeythersCom.Intelligence.LLMClient

  @impl true
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    generate(prompt, opts, Req)
  end

  def generate(prompt, opts, http_client) when is_binary(prompt) do
    endpoint = build_endpoint(opts)
    model = opts[:model] || "meta-llama/llama-3.1-8b-instruct"
    timeout_ms = opts[:timeout_ms] || 30_000
    api_key = opts[:api_key]
    log_requests? = opts[:log_requests] || false

    if is_binary(api_key) and String.trim(api_key) != "" do
      payload = build_payload(prompt, opts)
      headers = build_headers(opts, api_key)

      maybe_log_request(endpoint, payload, timeout_ms, log_requests?)

      started_at_ms = System.monotonic_time(:millisecond)

      result =
        endpoint
        |> request_generate(http_client, payload, headers, timeout_ms)
        |> parse_response(model)

      maybe_log_response(result, started_at_ms, log_requests?)
      result
    else
      {:error, :missing_openrouter_api_key}
    end
  end

  defp build_endpoint(opts) do
    opts[:endpoint]
    |> Kernel.||("https://openrouter.ai/api/v1")
    |> normalize_endpoint()
    |> Kernel.<>("/chat/completions")
  end

  defp build_headers(opts, api_key) do
    base_headers = [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]

    base_headers
    |> maybe_add_header("http-referer", opts[:http_referer])
    |> maybe_add_header("x-title", opts[:site_name])
  end

  defp maybe_add_header(headers, _name, value) when value in [nil, ""], do: headers

  defp maybe_add_header(headers, name, value) do
    [{name, to_string(value)} | headers]
  end

  defp build_payload(prompt, opts) do
    %{
      model: opts[:model] || "meta-llama/llama-3.1-8b-instruct",
      messages: [%{role: "user", content: prompt}],
      temperature: opts[:temperature] || 0.4,
      max_tokens: opts[:num_predict] || 600
    }
  end

  defp request_generate(endpoint, http_client, payload, headers, timeout_ms) do
    http_client.post(endpoint,
      json: payload,
      headers: headers,
      receive_timeout: timeout_ms
    )
  end

  defp parse_response(
         {:ok,
          %{
            status: 200,
            body:
              %{
                "choices" => [%{"message" => %{"content" => response_text}} | _]
              } = body
          }},
         model
       )
       when is_binary(response_text) do
    {:ok,
     %{
       text: response_text,
       model: model,
       usage: normalize_usage(Map.get(body, "usage")),
       provider_generation_id: normalize_string(Map.get(body, "id"))
     }}
  end

  defp parse_response({:ok, %{status: status, body: body}}, _model) do
    {:error, {:request_failed, status, body}}
  end

  defp parse_response({:error, reason}, _model), do: {:error, reason}

  defp maybe_log_request(_endpoint, _payload, _timeout_ms, false), do: :ok

  defp maybe_log_request(endpoint, payload, timeout_ms, true) do
    prompt =
      case payload[:messages] do
        [%{content: content} | _] when is_binary(content) -> content
        _ -> ""
      end

    prompt_preview = prompt |> String.slice(0, 220) |> String.replace(~r/\s+/, " ")

    Logger.info(
      "llm_request method=POST endpoint=#{endpoint} model=#{payload[:model]} timeout_ms=#{timeout_ms} temperature=#{payload[:temperature]} max_tokens=#{payload[:max_tokens]} prompt_chars=#{String.length(prompt)} prompt_preview=#{inspect(prompt_preview)}"
    )
  end

  defp maybe_log_response(_result, _started_at_ms, false), do: :ok

  defp maybe_log_response(result, started_at_ms, true) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

    case result do
      {:ok, %{model: model, text: text}} ->
        Logger.info(
          "llm_response status=ok elapsed_ms=#{elapsed_ms} model=#{model} response_chars=#{String.length(text)}"
        )

      {:error, {:request_failed, status, _body}} ->
        Logger.warning(
          "llm_response status=request_failed http_status=#{status} elapsed_ms=#{elapsed_ms}"
        )

      {:error, reason} ->
        Logger.warning(
          "llm_response status=error reason=#{inspect(reason)} elapsed_ms=#{elapsed_ms}"
        )
    end
  end

  defp normalize_endpoint(endpoint) do
    endpoint
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp normalize_usage(%{} = usage) do
    %{
      input_tokens: normalize_int(Map.get(usage, "prompt_tokens")),
      output_tokens: normalize_int(Map.get(usage, "completion_tokens")),
      total_tokens: normalize_int(Map.get(usage, "total_tokens")),
      provider_cost: normalize_number(Map.get(usage, "cost")),
      provider_cost_currency: "credits",
      is_byok: Map.get(usage, "is_byok")
    }
  end

  defp normalize_usage(_), do: %{}

  defp normalize_int(value) when is_integer(value), do: max(value, 0)
  defp normalize_int(value) when is_float(value), do: max(trunc(value), 0)

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> max(parsed, 0)
      _ -> nil
    end
  end

  defp normalize_int(_), do: nil

  defp normalize_number(value) when is_integer(value) or is_float(value), do: value

  defp normalize_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_number(_), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_), do: nil
end
