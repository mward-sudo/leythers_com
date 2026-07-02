defmodule LeythersCom.Intelligence.DecisionEngine.Deterministic do
  @moduledoc false

  alias LeythersCom.Intelligence.StorySimilarity

  @default_article_similarity_update_threshold 0.45
  @default_headline_recent_similarity_threshold 0.72

  def decide_similarity_action(attrs, entries, opts \\ [])
      when is_map(attrs) and is_list(entries) do
    threshold =
      Keyword.get(
        opts,
        :article_similarity_update_threshold,
        @default_article_similarity_update_threshold
      )

    headline_threshold =
      Keyword.get(
        opts,
        :headline_recent_similarity_threshold,
        @default_headline_recent_similarity_threshold
      )

    case best_similar_published_match(attrs, entries) do
      %{article_id: article_id, text_score: text_score, title_score: title_score}
      when is_binary(article_id) and
             (text_score >= threshold or title_score >= headline_threshold) ->
        %{
          triage_action: :update,
          target_article_id: article_id,
          decision_source: "deterministic",
          decision_confidence: Float.round(max(text_score, title_score), 4),
          fallback_reason: nil
        }

      _ ->
        %{
          triage_action: :new,
          target_article_id: nil,
          decision_source: "deterministic",
          decision_confidence: 0.0,
          fallback_reason: nil
        }
    end
  end

  defp best_similar_published_match(attrs, entries) do
    candidate_text =
      [
        Map.get(attrs, :headline, ""),
        Map.get(attrs, :summary, ""),
        Map.get(attrs, :body_html, "")
      ]
      |> Enum.join(" ")
      |> sanitize_plain_text()

    entries
    |> Enum.map(fn entry ->
      article_text =
        [
          Map.get(entry, :headline, ""),
          Map.get(entry, :summary, ""),
          Map.get(entry, :article_html, "")
        ]
        |> Enum.join(" ")
        |> sanitize_plain_text()

      %{
        article_id: Map.get(entry, :article_id),
        text_score: StorySimilarity.score(candidate_text, article_text),
        title_score:
          StorySimilarity.score(
            sanitize_plain_text(Map.get(attrs, :headline, "")),
            sanitize_plain_text(Map.get(entry, :headline, ""))
          )
      }
    end)
    |> Enum.max_by(fn result -> max(result.text_score, result.title_score) end, fn -> nil end)
  end

  defp sanitize_plain_text(value) when is_binary(value) do
    value
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sanitize_plain_text(_value), do: ""
end
