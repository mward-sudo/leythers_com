defmodule LeythersCom.Intelligence.LLMClient.Ollama do
  @moduledoc """
  Ollama-backed LLM adapter.

  Uses the `/api/generate` endpoint with `stream: false` for deterministic,
  single-response requests.
  """

  require Logger

  @behaviour LeythersCom.Intelligence.LLMClient

  @impl true
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    generate(prompt, opts, Req)
  end

  def generate(prompt, opts, http_client) when is_binary(prompt) do
    endpoint = build_endpoint(opts)
    model = opts[:model] || "qwen3:1.7b"
    timeout_ms = opts[:timeout_ms] || 30_000
    payload = build_payload(prompt, opts)
    log_requests? = opts[:log_requests] || false

    maybe_log_request(endpoint, payload, timeout_ms, log_requests?)

    started_at_ms = System.monotonic_time(:millisecond)

    result =
      endpoint
      |> request_generate(http_client, payload, timeout_ms)
      |> parse_response(model)

    maybe_log_response(result, started_at_ms, log_requests?)
    result
  end

  defp build_endpoint(opts) do
    opts[:endpoint]
    |> Kernel.||("http://127.0.0.1:11434")
    |> normalize_endpoint()
    |> Kernel.<>("/api/generate")
  end

  defp build_payload(prompt, opts) do
    %{
      model: opts[:model] || "qwen3:1.7b",
      prompt: prompt,
      stream: false,
      options: %{
        temperature: opts[:temperature] || 0.4,
        num_predict: opts[:num_predict] || 600
      }
    }
  end

  defp request_generate(endpoint, http_client, payload, timeout_ms) do
    http_client.post(endpoint, json: payload, receive_timeout: timeout_ms)
  end

  defp parse_response(
         {:ok, %{status: 200, body: %{"response" => response_text, "model" => response_model}}},
         _model
       ) do
    {:ok, %{text: response_text, model: response_model}}
  end

  defp parse_response({:ok, %{status: 200, body: %{"response" => response_text}}}, model) do
    {:ok, %{text: response_text, model: model}}
  end

  defp parse_response({:ok, %{status: status, body: body}}, _model) do
    {:error, {:request_failed, status, body}}
  end

  defp parse_response({:error, reason}, _model), do: {:error, reason}

  defp maybe_log_request(_endpoint, _payload, _timeout_ms, false), do: :ok

  defp maybe_log_request(endpoint, payload, timeout_ms, true) do
    prompt = payload[:prompt] || ""
    prompt_preview = prompt |> String.slice(0, 220) |> String.replace(~r/\s+/, " ")

    Logger.info(
      "llm_request method=POST endpoint=#{endpoint} model=#{payload[:model]} stream=#{payload[:stream]} timeout_ms=#{timeout_ms} temperature=#{get_in(payload, [:options, :temperature])} num_predict=#{get_in(payload, [:options, :num_predict])} prompt_chars=#{String.length(prompt)} prompt_preview=#{inspect(prompt_preview)}"
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
        Logger.warning("llm_response status=request_failed http_status=#{status} elapsed_ms=#{elapsed_ms}")

      {:error, reason} ->
        Logger.warning("llm_response status=error reason=#{inspect(reason)} elapsed_ms=#{elapsed_ms}")
    end
  end

  defp normalize_endpoint(endpoint) do
    endpoint
    |> to_string()
    |> String.trim_trailing("/")
  end
end
