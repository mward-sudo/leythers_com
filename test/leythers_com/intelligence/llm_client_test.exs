defmodule LeythersCom.Intelligence.LLMClientTest do
  use ExUnit.Case, async: false

  alias LeythersCom.Intelligence.LLMClient
  alias LeythersCom.Intelligence.LLMGuard

  setup do
    LLMGuard.report_success()
    _ = :sys.get_state(LLMGuard)
    :ok
  end

  defmodule FakeAdapter do
    @behaviour LeythersCom.Intelligence.LLMClient

    @impl true
    def generate(prompt, opts) do
      {:ok, %{text: "echo: " <> prompt, model: opts[:model] || "fake"}}
    end
  end

  defmodule FailingAdapter do
    @behaviour LeythersCom.Intelligence.LLMClient

    @impl true
    def generate(_prompt, _opts) do
      {:error, {:request_failed, 500, %{"error" => "upstream"}}}
    end
  end

  test "uses configured adapter and merges config with opts" do
    original = Application.get_env(:leythers_com, :llm)

    on_exit(fn ->
      if original do
        Application.put_env(:leythers_com, :llm, original)
      else
        Application.delete_env(:leythers_com, :llm)
      end
    end)

    Application.put_env(:leythers_com, :llm,
      adapter: FakeAdapter,
      model: "config-model"
    )

    assert {:ok, %{text: "echo: test prompt", model: "override-model"}} =
             LLMClient.generate("test prompt", model: "override-model")
  end

  test "opens circuit after repeated transient failures" do
    llm_original = Application.get_env(:leythers_com, :llm)
    guard_original = Application.get_env(:leythers_com, :llm_guard)

    on_exit(fn ->
      if llm_original do
        Application.put_env(:leythers_com, :llm, llm_original)
      else
        Application.delete_env(:leythers_com, :llm)
      end

      if guard_original do
        Application.put_env(:leythers_com, :llm_guard, guard_original)
      else
        Application.delete_env(:leythers_com, :llm_guard)
      end
    end)

    Application.put_env(:leythers_com, :llm, adapter: FailingAdapter)
    Application.put_env(:leythers_com, :llm_guard, failure_threshold: 2, open_cooldown_ms: 60_000)

    assert {:error, {:request_failed, 500, _}} = LLMClient.generate("one")
    assert {:error, {:request_failed, 500, _}} = LLMClient.generate("two")
    assert {:error, :llm_circuit_open} = LLMClient.generate("three")
  end

  test "returns rate limited when requests exceed limit and max wait is zero" do
    llm_original = Application.get_env(:leythers_com, :llm)
    rate_original = Application.get_env(:leythers_com, :llm_rate_limit)

    on_exit(fn ->
      if llm_original do
        Application.put_env(:leythers_com, :llm, llm_original)
      else
        Application.delete_env(:leythers_com, :llm)
      end

      if rate_original do
        Application.put_env(:leythers_com, :llm_rate_limit, rate_original)
      else
        Application.delete_env(:leythers_com, :llm_rate_limit)
      end
    end)

    Application.put_env(:leythers_com, :llm, adapter: FakeAdapter)

    unique_key = "llm:test:#{System.unique_integer([:positive])}"

    assert {:ok, %{text: "echo: first", model: "fake"}} =
             LLMClient.generate("first",
               rate_limit: [
                 enabled: true,
                 key: unique_key,
                 scale_ms: 60_000,
                 limit: 1,
                 max_wait_ms: 0
               ]
             )

    assert {:error, :llm_rate_limited} =
             LLMClient.generate("second",
               rate_limit: [
                 enabled: true,
                 key: unique_key,
                 scale_ms: 60_000,
                 limit: 1,
                 max_wait_ms: 0
               ]
             )
  end
end
