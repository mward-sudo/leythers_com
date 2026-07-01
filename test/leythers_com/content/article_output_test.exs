defmodule LeythersCom.Content.ArticleOutputTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LeythersCom.Content.ArticleOutput

  describe "new/3" do
    test "creates an ArticleOutput struct with trimmed values" do
      output = ArticleOutput.new("  Headline  ", "  Summary  ", "  Body  ")

      assert output.headline == "Headline"
      assert output.summary == "Summary"
      assert output.body == "Body"
    end
  end

  describe "validate_headline/1" do
    test "accepts a valid headline with Leigh angle" do
      assert [] == ArticleOutput.validate_headline("Leigh Squad Update Ahead of Fixture")
    end

    test "accepts a headline with team reference" do
      assert [] == ArticleOutput.validate_headline("Leopards Show Promise in Training")
    end

    test "rejects headline without Leigh angle" do
      issues = ArticleOutput.validate_headline("Manchester Derby Heats Up")
      assert Enum.any?(issues, &String.contains?(&1, "Leigh perspective"))
    end

    test "rejects headline exceeding max length" do
      long_headline =
        "This is a very long headline that exceeds the maximum allowed length and should be rejected by the validator"

      issues = ArticleOutput.validate_headline(long_headline)
      assert Enum.any?(issues, &String.contains?(&1, "exceeds"))
    end

    test "rejects headline with clickbait patterns" do
      issues =
        ArticleOutput.validate_headline("Leigh Leopards: Shocking Update You Won't Believe!")

      assert Enum.any?(issues, &String.contains?(&1, "clickbait"))
    end

    test "accepts factual headlines with transfers/signings" do
      assert [] ==
               ArticleOutput.validate_headline("Leigh Sign Welsh International for Squad Boost")
    end
  end

  describe "validate_summary/1" do
    test "accepts a valid plain-text summary" do
      summary = "Leigh is looking strong heading into the weekend."
      assert [] == ArticleOutput.validate_summary(summary)
    end

    test "rejects summary with HTML tags" do
      issues = ArticleOutput.validate_summary("Leigh update: <b>Squad boost</b> incoming")
      assert Enum.any?(issues, &String.contains?(&1, "plain text"))
    end

    test "rejects summary with markdown links" do
      issues =
        ArticleOutput.validate_summary("Check [this link](https://example.com) for details")

      assert Enum.any?(issues, &String.contains?(&1, "plain text"))
    end

    test "rejects summary exceeding max length" do
      long_summary = String.duplicate("This is a very long summary. ", 30)
      issues = ArticleOutput.validate_summary(long_summary)
      assert Enum.any?(issues, &String.contains?(&1, "exceeds"))
    end

    test "rejects summary with excessive hedging without rumour context" do
      issues =
        ArticleOutput.validate_summary(
          "Leigh might possibly be looking at a transfer that could happen maybe next week."
        )

      assert Enum.any?(issues, &String.contains?(&1, "hedging"))
    end

    test "accepts summary with hedging in rumour context" do
      summary = "Rumour: Leigh might be looking at an Australian signing."
      assert [] == ArticleOutput.validate_summary(summary)
    end
  end

  describe "validate_body/1" do
    test "accepts non-empty body" do
      assert [] == ArticleOutput.validate_body("This is the full article content.")
    end

    test "rejects empty body" do
      issues = ArticleOutput.validate_body("")
      assert Enum.any?(issues, &String.contains?(&1, "empty"))
    end

    test "rejects whitespace-only body" do
      issues = ArticleOutput.validate_body("   \n  \t  ")
      assert Enum.any?(issues, &String.contains?(&1, "empty"))
    end
  end

  describe "validate/1" do
    test "validates a complete, valid article output" do
      output =
        ArticleOutput.new(
          "Leigh Prepare for Challenge Ahead",
          "Leigh's squad is ready for the upcoming fixture.",
          "Full article body with multiple paragraphs discussing the team's preparation and strategy."
        )

      assert {:ok, ^output} = ArticleOutput.validate(output)
    end

    test "collects issues from headline validation" do
      output =
        ArticleOutput.new(
          "Manchester Derby Drama",
          "Valid summary here.",
          "Valid body here."
        )

      {:error, issues} = ArticleOutput.validate(output)
      assert Enum.any?(issues, &String.contains?(&1, "Leigh perspective"))
    end

    test "collects issues from summary validation" do
      output =
        ArticleOutput.new(
          "Leigh Leopards Update",
          "Check <b>this link</b> for more info.",
          "Valid body here."
        )

      {:error, issues} = ArticleOutput.validate(output)
      assert Enum.any?(issues, &String.contains?(&1, "plain text"))
    end

    test "collects issues from body validation" do
      output =
        ArticleOutput.new(
          "Leigh Leopards Update",
          "Valid summary here.",
          ""
        )

      {:error, issues} = ArticleOutput.validate(output)
      assert Enum.any?(issues, &String.contains?(&1, "empty"))
    end

    test "collects multiple issues across all parts" do
      output =
        ArticleOutput.new(
          "Manchester Update with <clickbait>You Won't Believe</clickbait>",
          "Summary with <b>HTML</b>",
          ""
        )

      {:error, issues} = ArticleOutput.validate(output)
      assert length(issues) >= 2
    end
  end
end
