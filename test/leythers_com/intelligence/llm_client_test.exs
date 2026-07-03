defmodule LeythersCom.Intelligence.LLMClientTest do
  use LeythersCom.DataCase, async: false

  alias LeythersCom.Intelligence
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

  defmodule FlakyAdapter do
    @behaviour LeythersCom.Intelligence.LLMClient

    @impl true
    def generate(_prompt, _opts) do
      attempts = Process.get(:flaky_attempts, 0) + 1
      Process.put(:flaky_attempts, attempts)

      if attempts < 3 do
        {:error, {:request_failed, 500, %{"error" => "transient"}}}
      else
        {:ok, %{text: "recovered", model: "flaky"}}
      end
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

  test "persists prompt, context, and response logs for successful calls" do
    original = Application.get_env(:leythers_com, :llm)

    on_exit(fn ->
      if original do
        Application.put_env(:leythers_com, :llm, original)
      else
        Application.delete_env(:leythers_com, :llm)
      end
    end)

    Application.put_env(:leythers_com, :llm, adapter: FakeAdapter, model: "config-model")

    assert {:ok, %{text: "echo: prompt body", model: "config-model"}} =
             LLMClient.generate("prompt body",
               log_context: %{story: %{id: "story-1", title: "Leigh update"}},
               log_metadata: %{purpose: "test_success_logging"}
             )

    [log | _] = Intelligence.list_llm_interaction_logs(%{page: 1, per_page: 5}).entries

    assert log.prompt == "prompt body"
    assert log.status == "ok"
    assert log.response_text == "echo: prompt body"
    assert log.metadata["purpose"] == "test_success_logging"
    assert log.context["story"]["title"] == "Leigh update"
  end

  test "persists error logs for failed calls" do
    original = Application.get_env(:leythers_com, :llm)

    on_exit(fn ->
      if original do
        Application.put_env(:leythers_com, :llm, original)
      else
        Application.delete_env(:leythers_com, :llm)
      end
    end)

    Application.put_env(:leythers_com, :llm, adapter: FailingAdapter)

    assert {:error, {:request_failed, 500, %{"error" => "upstream"}}} =
             LLMClient.generate("broken prompt",
               retry: [enabled: false],
               log_metadata: %{purpose: "test_error_logging"}
             )

    [log | _] = Intelligence.list_llm_interaction_logs(%{page: 1, per_page: 1}).entries

    assert log.prompt == "broken prompt"
    assert log.status == "error"
    assert log.error_summary =~ "request_failed"
    assert log.metadata["purpose"] == "test_error_logging"
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

    assert {:error, {:request_failed, 500, _}} =
             LLMClient.generate("one", retry: [enabled: false])

    assert {:error, {:request_failed, 500, _}} =
             LLMClient.generate("two", retry: [enabled: false])

    assert {:error, :llm_circuit_open} = LLMClient.generate("three", retry: [enabled: false])
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

  test "retries transient failures and succeeds within retry budget" do
    llm_original = Application.get_env(:leythers_com, :llm)

    on_exit(fn ->
      if llm_original do
        Application.put_env(:leythers_com, :llm, llm_original)
      else
        Application.delete_env(:leythers_com, :llm)
      end

      Process.delete(:flaky_attempts)
    end)

    Process.put(:flaky_attempts, 0)
    Application.put_env(:leythers_com, :llm, adapter: FlakyAdapter)

    assert {:ok, %{text: "recovered", model: "flaky"}} =
             LLMClient.generate("retry me",
               retry: [
                 enabled: true,
                 max_attempts: 3,
                 base_delay_ms: 1,
                 max_delay_ms: 4,
                 jitter_ms: 0
               ]
             )

    assert Process.get(:flaky_attempts) == 3
  end

  test "returns last transient error when retry budget is exhausted" do
    llm_original = Application.get_env(:leythers_com, :llm)

    on_exit(fn ->
      if llm_original do
        Application.put_env(:leythers_com, :llm, llm_original)
      else
        Application.delete_env(:leythers_com, :llm)
      end
    end)

    Application.put_env(:leythers_com, :llm, adapter: FailingAdapter)

    assert {:error, {:request_failed, 500, %{"error" => "upstream"}}} =
             LLMClient.generate("still broken",
               retry: [
                 enabled: true,
                 max_attempts: 2,
                 base_delay_ms: 1,
                 max_delay_ms: 2,
                 jitter_ms: 0
               ]
             )
  end
end
