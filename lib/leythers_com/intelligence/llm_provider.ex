defmodule LeythersCom.Intelligence.LLMProvider do
  @moduledoc false

  alias LeythersCom.Intelligence.LLMClient.Ollama
  alias LeythersCom.Intelligence.LLMClient.OpenRouter

  @providers [:openrouter, :ollama]

  def providers, do: @providers

  def current_provider do
    :leythers_com
    |> Application.get_env(:llm_provider, :ollama)
    |> normalize_provider!()
  end

  def llm_config do
    active_config = Application.get_env(:leythers_com, :llm, [])

    if Keyword.has_key?(active_config, :adapter) do
      active_config
    else
      profile_for(current_provider(), active_config)
    end
  end

  def activate(provider) do
    provider = normalize_provider!(provider)
    profile = profile_for(provider, Application.get_env(:leythers_com, :llm, []))

    Application.put_env(:leythers_com, :llm_provider, provider)
    Application.put_env(:leythers_com, :llm, profile)

    :ok
  end

  def normalize_provider(provider) when provider in @providers, do: {:ok, provider}

  def normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> case do
      "openrouter" -> {:ok, :openrouter}
      "ollama" -> {:ok, :ollama}
      _ -> :error
    end
  end

  def normalize_provider(_provider), do: :error

  defp normalize_provider!(provider) do
    case normalize_provider(provider) do
      {:ok, normalized_provider} -> normalized_provider
      :error -> :ollama
    end
  end

  def default_profiles do
    %{
      openrouter: [
        adapter: OpenRouter,
        endpoint: "https://openrouter.ai/api/v1",
        model: "meta-llama/llama-3.1-8b-instruct",
        temperature: 0.4,
        num_predict: 600,
        timeout_ms: 30_000,
        log_requests: false
      ],
      ollama: [
        adapter: Ollama,
        endpoint: "http://127.0.0.1:11434",
        model: "llama3.1:8b",
        temperature: 0.4,
        num_predict: 600,
        timeout_ms: 30_000,
        log_requests: false
      ]
    }
  end

  defp profile_for(provider, fallback) do
    profiles = Application.get_env(:leythers_com, :llm_profiles, %{})

    case get_profile(profiles, provider) do
      nil -> fallback
      profile -> profile
    end
  end

  defp get_profile(profiles, provider) when is_map(profiles), do: Map.get(profiles, provider)
  defp get_profile(profiles, provider) when is_list(profiles), do: Keyword.get(profiles, provider)
  defp get_profile(_profiles, _provider), do: nil
end
