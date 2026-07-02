defmodule LeythersCom.Intelligence.QualityRubric do
  @moduledoc """
  Scores AI article output using lightweight rubric dimensions.
  """

  @type score_map :: %{
          specificity: non_neg_integer(),
          novelty: non_neg_integer(),
          grounding: non_neg_integer(),
          overall: non_neg_integer()
        }

  @max_score 100

  def score(%{headline: headline, summary: summary, body: body}) do
    specificity = score_specificity(headline, summary, body)
    novelty = score_novelty(summary, body)
    grounding = score_grounding(body)

    overall =
      round(
        specificity * 0.35 +
          novelty * 0.30 +
          grounding * 0.35
      )

    %{
      specificity: specificity,
      novelty: novelty,
      grounding: grounding,
      overall: clamp(overall)
    }
  end

  def score(_output) do
    %{specificity: 0, novelty: 0, grounding: 0, overall: 0}
  end

  defp score_specificity(headline, summary, body) do
    word_count =
      [headline, summary, body]
      |> Enum.map(&token_count/1)
      |> Enum.sum()

    cond do
      word_count >= 220 -> 90
      word_count >= 140 -> 75
      word_count >= 80 -> 60
      word_count >= 40 -> 45
      true -> 30
    end
  end

  defp score_novelty(summary, body) do
    combined = "#{summary} #{body}"

    generic_penalty =
      ["great game", "big win", "important result", "strong performance"]
      |> Enum.count(&String.contains?(String.downcase(combined), &1))
      |> Kernel.*(12)

    base =
      cond do
        token_count(body) >= 180 -> 85
        token_count(body) >= 120 -> 70
        token_count(body) >= 70 -> 55
        true -> 40
      end

    clamp(base - generic_penalty)
  end

  defp score_grounding(body) do
    downcased = String.downcase(body || "")

    citation_hits =
      ["according to", "reported by", "from", "via", "at "]
      |> Enum.count(&String.contains?(downcased, &1))

    score =
      cond do
        citation_hits >= 3 -> 88
        citation_hits == 2 -> 75
        citation_hits == 1 -> 62
        true -> 45
      end

    clamp(score)
  end

  defp token_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp token_count(_), do: 0

  defp clamp(value) when value < 0, do: 0
  defp clamp(value) when value > @max_score, do: @max_score
  defp clamp(value), do: value
end
