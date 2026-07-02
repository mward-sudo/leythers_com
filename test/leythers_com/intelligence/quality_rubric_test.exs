defmodule LeythersCom.Intelligence.QualityRubricTest do
  use ExUnit.Case, async: true

  alias LeythersCom.Intelligence.QualityRubric

  describe "score/1" do
    test "returns per-dimension scores and overall score for structured output" do
      output = %{
        headline: "Leigh prepare tactical shift before cup semi-final",
        summary: "Coaches are balancing tempo and edge defence for a tight matchup.",
        body:
          "According to club staff, Leigh are adjusting their middle rotation this week. " <>
            "Reported by local outlets, the squad focused on line speed at training. " <>
            "From the captain's comments, discipline is a key focus before kick-off. " <>
            "The selection meeting is expected to finalize late fitness calls."
      }

      score = QualityRubric.score(output)

      assert is_integer(score.specificity)
      assert is_integer(score.novelty)
      assert is_integer(score.grounding)
      assert is_integer(score.overall)
      assert score.overall >= 0
      assert score.overall <= 100
    end

    test "returns zeroed scores for invalid payloads" do
      assert %{specificity: 0, novelty: 0, grounding: 0, overall: 0} =
               QualityRubric.score(%{})
    end
  end
end
