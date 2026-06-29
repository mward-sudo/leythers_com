defmodule LeythersCom.Intelligence.LLMClient do
  @moduledoc """
  Configurable LLM client facade used by intelligence/editorial orchestration.

  The configured adapter is responsible for provider-specific request/response
  behavior. Defaults are configured for local Ollama usage.
  """

  @type result :: {:ok, %{text: String.t(), model: String.t()}} | {:error, term()}

  @callback generate(String.t(), keyword()) :: result()

  @spec generate(String.t(), keyword()) :: result()
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    config = llm_config()
    adapter = config[:adapter] || LeythersCom.Intelligence.LLMClient.Ollama

    adapter.generate(prompt, Keyword.merge(config, opts))
  end

  @spec llm_config() :: keyword()
  def llm_config do
    Application.get_env(:leythers_com, :llm, [])
  end
end
