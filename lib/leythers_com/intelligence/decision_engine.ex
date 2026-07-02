defmodule LeythersCom.Intelligence.DecisionEngine do
  @moduledoc """
  LLM-first decision engine for update-vs-new article targeting.

  It delegates to a primary engine and falls back to deterministic decisions
  when LLM is unavailable or returns an invalid response.
  """

  alias LeythersCom.Intelligence.DecisionEngine.Deterministic
  alias LeythersCom.Intelligence.DecisionEngine.LLM

  @type decision :: %{
          triage_action: :new | :update,
          target_article_id: String.t() | nil,
          decision_source: String.t(),
          decision_confidence: float(),
          fallback_reason: String.t() | nil
        }

  @callback decide_similarity_action(map(), list(map()), keyword()) ::
              {:ok, decision()} | {:error, term()}

  @spec decide_similarity_action(map(), list(map()), keyword()) :: {:ok, decision()}
  def decide_similarity_action(attrs, entries, opts \\ [])

  def decide_similarity_action(attrs, entries, opts) when is_map(attrs) and is_list(entries) do
    llm_enabled? = Keyword.get(opts, :llm_enabled, true)

    if llm_enabled? do
      case LLM.decide_similarity_action(attrs, entries, opts) do
        {:ok, decision} ->
          {:ok, decision}

        {:error, reason} ->
          {:ok,
           Deterministic.decide_similarity_action(attrs, entries, opts)
           |> put_fallback_reason(reason)}
      end
    else
      {:ok, Deterministic.decide_similarity_action(attrs, entries, opts)}
    end
  end

  def decide_similarity_action(_attrs, _entries, _opts) do
    {:ok,
     %{
       triage_action: :new,
       target_article_id: nil,
       decision_source: "deterministic",
       decision_confidence: 0.0,
       fallback_reason: nil
     }}
  end

  defp put_fallback_reason(decision, reason) do
    Map.put(decision, :fallback_reason, inspect(reason))
  end
end
