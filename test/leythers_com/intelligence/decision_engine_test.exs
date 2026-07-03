defmodule LeythersCom.Intelligence.DecisionEngineTest do
  use ExUnit.Case, async: false

  alias LeythersCom.Intelligence.DecisionEngine

  defmodule SuccessAdapter do
    @behaviour LeythersCom.Intelligence.LLMClient

    @impl true
    def generate(_prompt, _opts) do
      {:ok,
       %{
         text:
           ~s({"action":"update","target_article_id":"11111111-1111-1111-1111-111111111111","confidence":0.87,"reason":"same story"}),
         model: "test"
       }}
    end
  end

  defmodule FailureAdapter do
    @behaviour LeythersCom.Intelligence.LLMClient

    @impl true
    def generate(_prompt, _opts), do: {:error, {:request_failed, 500, %{}}}
  end

  defmodule LowConfidenceAdapter do
    @behaviour LeythersCom.Intelligence.LLMClient

    @impl true
    def generate(_prompt, _opts) do
      {:ok,
       %{
         text:
           ~s({"action":"update","target_article_id":"11111111-1111-1111-1111-111111111111","confidence":0.34,"reason":"same story"}),
         model: "test"
       }}
    end
  end

  setup do
    original_llm = Application.get_env(:leythers_com, :llm)

    on_exit(fn ->
      if original_llm do
        Application.put_env(:leythers_com, :llm, original_llm)
      else
        Application.delete_env(:leythers_com, :llm)
      end
    end)

    :ok
  end

  test "uses llm decision when available" do
    Application.put_env(:leythers_com, :llm, adapter: SuccessAdapter)

    attrs = %{headline: "Leigh injury update", summary: "same topic", body_html: "<p>update</p>"}

    entries = [
      %{
        article_id: "11111111-1111-1111-1111-111111111111",
        headline: "Leigh injury update",
        summary: "prior",
        article_html: "<p>prior</p>"
      }
    ]

    assert {:ok, decision} =
             DecisionEngine.decide_similarity_action(attrs, entries, llm_enabled: true)

    assert decision.triage_action == :update
    assert decision.target_article_id == "11111111-1111-1111-1111-111111111111"
    assert decision.decision_source == "llm"
    assert decision.decision_confidence > 0.8
  end

  test "falls back to deterministic when llm fails" do
    Application.put_env(:leythers_com, :llm, adapter: FailureAdapter)

    attrs =
      %{
        headline: "Leigh sign prop forward",
        summary: "transfer update",
        body_html: "<p>Leigh sign prop</p>"
      }

    entries = [
      %{
        article_id: "22222222-2222-2222-2222-222222222222",
        headline: "Leigh sign prop forward",
        summary: "transfer update",
        article_html: "<p>Leigh sign prop</p>"
      }
    ]

    assert {:ok, decision} =
             DecisionEngine.decide_similarity_action(attrs, entries, llm_enabled: true)

    assert decision.decision_source == "deterministic"
    assert decision.fallback_reason =~ "request_failed"
  end

  test "downgrades low-confidence llm update decision to new" do
    Application.put_env(:leythers_com, :llm, adapter: LowConfidenceAdapter)

    attrs = %{headline: "Leigh injury update", summary: "same topic", body_html: "<p>update</p>"}

    entries = [
      %{
        article_id: "11111111-1111-1111-1111-111111111111",
        headline: "Leigh injury update",
        summary: "prior",
        article_html: "<p>prior</p>"
      }
    ]

    assert {:ok, decision} =
             DecisionEngine.decide_similarity_action(attrs, entries,
               llm_enabled: true,
               min_llm_update_confidence: 0.65
             )

    assert decision.decision_source == "llm"
    assert decision.triage_action == :new
    assert decision.target_article_id == nil
    assert decision.fallback_reason == "llm_update_guardrail"
  end
end
