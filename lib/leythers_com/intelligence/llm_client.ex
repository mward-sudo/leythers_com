defmodule LeythersCom.Intelligence.LLMClient do
  @moduledoc """
  Configurable LLM client facade used by intelligence/editorial orchestration.

  The configured adapter is responsible for provider-specific request/response
  behavior. Defaults are configured for local Ollama usage.
  """

  @type result :: {:ok, %{text: String.t(), model: String.t()}} | {:error, term()}

  alias __MODULE__.Ollama
  alias LeythersCom.Intelligence.LLMGuard

  @callback generate(String.t(), keyword()) :: result()

  @spec generate(String.t(), keyword()) :: result()
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    if LLMGuard.allow?(), do: do_generate(prompt, opts), else: {:error, :llm_circuit_open}
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
end
