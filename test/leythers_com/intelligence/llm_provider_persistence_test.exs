defmodule LeythersCom.Intelligence.LLMProviderPersistenceTest do
  use LeythersCom.DataCase, async: false

  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.RuntimeSetting

  setup do
    runtime_env_original = Application.get_env(:leythers_com, :runtime_env)
    llm_provider_original = Application.get_env(:leythers_com, :llm_provider)
    llm_original = Application.get_env(:leythers_com, :llm)
    llm_profiles_original = Application.get_env(:leythers_com, :llm_profiles)

    Application.put_env(:leythers_com, :runtime_env, :dev)

    Application.put_env(:leythers_com, :llm_profiles, %{
      openrouter: [
        adapter: LeythersCom.Intelligence.LLMClient.OpenRouter,
        model: "openrouter-test"
      ],
      ollama: [adapter: LeythersCom.Intelligence.LLMClient.Ollama, model: "ollama-test"]
    })

    on_exit(fn ->
      reset_env(:runtime_env, runtime_env_original)
      reset_env(:llm_provider, llm_provider_original)
      reset_env(:llm, llm_original)
      reset_env(:llm_profiles, llm_profiles_original)
    end)

    :ok
  end

  test "set_dev_llm_provider persists preference and activates provider" do
    assert {:ok, :openrouter} = Intelligence.set_dev_llm_provider("openrouter")

    assert %RuntimeSetting{value: "openrouter"} =
             Repo.get_by(RuntimeSetting, key: "dev_llm_provider")

    assert Intelligence.current_llm_provider() == :openrouter
  end

  test "restore_dev_llm_provider loads persisted preference" do
    Repo.insert!(%RuntimeSetting{key: "dev_llm_provider", value: "openrouter"})

    Application.put_env(:leythers_com, :llm_provider, :ollama)
    Application.put_env(:leythers_com, :llm, adapter: LeythersCom.Intelligence.LLMClient.Ollama)

    assert {:ok, :openrouter} = Intelligence.restore_dev_llm_provider()
    assert Intelligence.current_llm_provider() == :openrouter
  end

  test "restore_dev_llm_provider prefers persisted preference over DEV_LLM_PROVIDER" do
    previous_env = System.get_env("DEV_LLM_PROVIDER")

    on_exit(fn ->
      case previous_env do
        nil -> System.delete_env("DEV_LLM_PROVIDER")
        value -> System.put_env("DEV_LLM_PROVIDER", value)
      end
    end)

    System.put_env("DEV_LLM_PROVIDER", "ollama")
    Repo.insert!(%RuntimeSetting{key: "dev_llm_provider", value: "openrouter"})

    Application.put_env(:leythers_com, :llm_provider, :ollama)
    Application.put_env(:leythers_com, :llm, adapter: LeythersCom.Intelligence.LLMClient.Ollama)

    assert {:ok, :openrouter} = Intelligence.restore_dev_llm_provider()
    assert Intelligence.current_llm_provider() == :openrouter
  end

  test "set_dev_llm_provider is blocked outside dev" do
    Application.put_env(:leythers_com, :runtime_env, :prod)

    assert {:error, :unsupported_environment} = Intelligence.set_dev_llm_provider(:openrouter)
    assert Repo.get_by(RuntimeSetting, key: "dev_llm_provider") == nil
  end

  test "set_dev_llm_provider works when llm_profiles is a keyword list" do
    Application.put_env(:leythers_com, :llm_profiles,
      openrouter: [adapter: LeythersCom.Intelligence.LLMClient.OpenRouter],
      ollama: [adapter: LeythersCom.Intelligence.LLMClient.Ollama]
    )

    assert {:ok, :openrouter} = Intelligence.set_dev_llm_provider(:openrouter)
    assert Intelligence.current_llm_provider() == :openrouter
  end

  defp reset_env(key, nil), do: Application.delete_env(:leythers_com, key)
  defp reset_env(key, value), do: Application.put_env(:leythers_com, key, value)
end
