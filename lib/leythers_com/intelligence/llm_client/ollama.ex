defmodule LeythersCom.Intelligence.LLMClient.Ollama do
  @moduledoc """
  Ollama-backed LLM adapter.

  Uses the `/api/generate` endpoint with `stream: false` for deterministic,
  single-response requests.
  """

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

    endpoint
    |> request_generate(http_client, payload, timeout_ms)
    |> parse_response(model)
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

  defp normalize_endpoint(endpoint) do
    endpoint
    |> to_string()
    |> String.trim_trailing("/")
  end
end
