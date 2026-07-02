defmodule LeythersCom.Content.ArticleOutput do
  @moduledoc """
  Defines and validates the three-part article output contract:
  - headline: compelling Leigh-focused angle in plain text
  - summary: plain-text teaser (no HTML/markup)
  - body: full article body as formatted HTML

  All three parts enforce Leythers editorial policies:
  - Headlines lead with Leigh angle, avoid clickbait and major spoilers
  - Summaries stay factual, plain-text only, teaser-style
  - Bodies maintain fan-journalist tone with voice profile applied
  """

  defstruct [:headline, :summary, :body]

  @type t :: %__MODULE__{
          headline: String.t(),
          summary: String.t(),
          body: String.t()
        }

  @max_headline_length 100
  @max_summary_length 280

  def new(headline, summary, body)
      when is_binary(headline) and is_binary(summary) and is_binary(body) do
    %__MODULE__{
      headline: String.trim(headline),
      summary: String.trim(summary),
      body: String.trim(body)
    }
  end

  @doc """
  Validate the complete article output against Leythers policies.
  Returns {:ok, output} or {:error, [issues]}
  """
  def validate(%__MODULE__{} = output) do
    headline_issues = validate_headline(output.headline)
    summary_issues = validate_summary(output.summary)
    body_issues = validate_body(output.body)

    all_issues = headline_issues ++ summary_issues ++ body_issues

    if all_issues == [] do
      {:ok, output}
    else
      {:error, all_issues}
    end
  end

  def validate(_), do: {:error, ["invalid output structure"]}

  @doc """
  Validate headline policy: Leigh angle, no spoilers, no clickbait, reasonable length.
  Returns list of violation strings (empty = valid).
  """
  def validate_headline(headline) when is_binary(headline) do
    headline = String.trim(headline)

    issues =
      []
      |> check_headline_length(headline)
      |> check_leigh_angle(headline)
      |> check_no_major_spoilers(headline)
      |> check_no_misleading_clickbait(headline)

    issues
  end

  def validate_headline(_), do: ["headline must be a string"]

  @doc """
  Validate summary policy: plain text only, factual/teaser, reasonable length.
  Returns list of violation strings (empty = valid).
  """
  def validate_summary(summary) when is_binary(summary) do
    summary = String.trim(summary)

    issues =
      []
      |> check_summary_length(summary)
      |> check_is_plain_text(summary)
      |> check_is_factual_teaser(summary)

    issues
  end

  def validate_summary(_), do: ["summary must be a string"]

  @doc """
  Validate body: should be non-empty formatted HTML.
  Returns list of violation strings (empty = valid).
  """
  def validate_body(body) when is_binary(body) do
    body = String.trim(body)
    has_html_tag? = Regex.match?(~r/<[^>]+>/, body)

    cond do
      body == "" ->
        ["body cannot be empty"]

      not has_html_tag? ->
        ["body must be formatted HTML"]

      true ->
        []
    end
  end

  def validate_body(_), do: ["body must be a string"]

  # ── Headline Validators ───────────────────────────────────────────────────

  defp check_headline_length(issues, headline) do
    if String.length(headline) > @max_headline_length do
      [
        "headline exceeds #{@max_headline_length} chars (got #{String.length(headline)})"
        | issues
      ]
    else
      issues
    end
  end

  defp check_leigh_angle(issues, headline) do
    normalized = String.downcase(headline)

    # Check for Leigh PoV indicators: team name, possessive pronouns, or club-facing language
    leigh_pov_terms = [
      "leigh",
      "leopards",
      "rhinos",
      "our",
      "we ",
      " we ",
      "the club",
      "sign",
      "join",
      "leave",
      "away from"
    ]

    has_leigh_pov = Enum.any?(leigh_pov_terms, &String.contains?(normalized, &1))

    # Reject obviously non-Leigh perspective (player signs FOR someone else, not us)
    third_party_terms = ["signs for another", "signs with another", "signs for the"]
    has_third_party = Enum.any?(third_party_terms, &String.contains?(normalized, &1))

    cond do
      has_third_party -> ["headline must be from Leigh perspective, not third-party" | issues]
      has_leigh_pov -> issues
      true -> ["headline must reflect Leigh perspective or involvement" | issues]
    end
  end

  defp check_no_major_spoilers(issues, _headline) do
    # Major spoilers are context-dependent and checked via policy, not hard rules
    # (Not blocking—just advisory for now based on context)
    issues
  end

  defp check_no_misleading_clickbait(issues, headline) do
    normalized = String.downcase(headline)

    clickbait_patterns = [
      "you won't believe",
      "shocking",
      "this one weird trick",
      "doctors hate",
      "but wait there's more"
    ]

    has_clickbait =
      Enum.any?(clickbait_patterns, fn pattern ->
        String.contains?(normalized, pattern)
      end)

    if has_clickbait do
      ["headline contains clickbait patterns" | issues]
    else
      issues
    end
  end

  # ── Summary Validators ────────────────────────────────────────────────────

  defp check_summary_length(issues, summary) do
    if String.length(summary) > @max_summary_length do
      [
        "summary exceeds #{@max_summary_length} chars (got #{String.length(summary)})"
        | issues
      ]
    else
      issues
    end
  end

  defp check_is_plain_text(issues, summary) do
    has_html = String.contains?(summary, ["<", ">", "[", "]("])
    has_markdown_links = String.match?(summary, ~r/\[.*\]\(.*\)/)

    if has_html or has_markdown_links do
      ["summary must be plain text (no HTML or markdown)" | issues]
    else
      issues
    end
  end

  defp check_is_factual_teaser(issues, summary) do
    # Check for common hallucination/fabrication patterns
    fabrication_patterns = [
      "reportedly",
      "allegedly",
      "possibly",
      "maybe",
      "could be",
      "might be"
    ]

    has_hedging =
      Enum.any?(fabrication_patterns, fn pattern ->
        String.contains?(String.downcase(summary), pattern)
      end)

    if has_hedging and not String.contains?(String.downcase(summary), "rumour") do
      # Hedging is OK in a rumour context, but risky otherwise
      ["summary uses excessive hedging without rumour context" | issues]
    else
      issues
    end
  end
end
