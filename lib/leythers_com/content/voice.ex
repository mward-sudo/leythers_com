defmodule LeythersCom.Content.Voice do
  @moduledoc """
  Editorial voice transforms for consistent output while minimizing extra model usage.

  Applies three types of transforms:
  1. Headline styling: rumour prefixes, consistent framing
  2. Summary validation: plain text enforcement, teaser-style requirements
  3. Body styling: rumour notices and HTML normalization

  All transforms are deterministic and require no LLM cost.
  """

  alias LeythersCom.Content.ArticleOutput

  @voice_config_key :voice_profile

  def profile do
    Application.get_env(:leythers_com, @voice_config_key, [])
  end

  @doc """
  Apply voice to a complete 3-part article output.
  Returns ArticleOutput struct with all three parts styled and validated.
  """
  def apply_to_output(%{headline: headline, summary: summary, body: body}, opts \\ []) do
    rumour? = Keyword.get(opts, :rumour, false)
    profile = Keyword.get(opts, :profile, profile())

    output =
      ArticleOutput.new(
        style_headline(headline, rumour?, profile),
        style_summary(summary, profile),
        style_body(body, rumour?, profile)
      )

    ArticleOutput.validate(output)
  end

  @doc """
  Legacy function for backward compatibility: apply voice to title and body only.
  """
  def apply(%{title: title, body: body}, opts \\ []) do
    rumour? = Keyword.get(opts, :rumour, false)
    profile = Keyword.get(opts, :profile, profile())

    %{
      title: style_title(title, rumour?, profile),
      body: style_body(body, rumour?, profile)
    }
  end

  @doc false
  def style_headline(headline, rumour?, profile) when is_binary(headline) do
    trimmed = String.trim(headline)
    rumour_prefix = profile[:rumour_title_prefix] || "Rumour:"

    if rumour? do
      if String.starts_with?(String.downcase(trimmed), String.downcase(rumour_prefix)) do
        trimmed
      else
        rumour_prefix <> " " <> trimmed
      end
    else
      trimmed
    end
  end

  def style_headline(_headline, _, _profile), do: ""

  @doc false
  def style_summary(summary, _profile) when is_binary(summary) do
    # Summaries are already plain text from the LLM or source
    # Just ensure trimming; no voice adjustments needed for summaries
    String.trim(summary)
  end

  def style_summary(_summary, _profile), do: ""

  # Legacy headline styling (for backward compatibility)
  defp style_title(title, true, profile) when is_binary(title) do
    trimmed = String.trim(title)
    rumour_prefix = profile[:rumour_title_prefix] || "Rumour:"

    if String.starts_with?(String.downcase(trimmed), String.downcase(rumour_prefix)) do
      trimmed
    else
      rumour_prefix <> " " <> trimmed
    end
  end

  defp style_title(title, false, _profile) when is_binary(title), do: String.trim(title)

  defp style_body(body, rumour?, profile) when is_binary(body) do
    body =
      body
      |> String.trim()
      |> normalize_html_body()

    rumour_notice =
      profile[:rumour_notice] || "Rumour mill warning: treat this as chatter until confirmed."

    base_body = if rumour?, do: prepend_html_paragraph(body, rumour_notice), else: body

    base_body
  end

  defp style_body(_body, rumour?, profile) do
    style_body("", rumour?, profile)
  end

  defp normalize_html_body(""), do: "<p></p>"

  defp normalize_html_body(text) do
    if Regex.match?(~r/<[^>]+>/, text) do
      text
    else
      escaped = Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
      "<p>#{escaped}</p>"
    end
  end

  defp prepend_html_paragraph(text, line) do
    if String.contains?(String.downcase(text), String.downcase(line)) do
      text
    else
      escaped = Phoenix.HTML.html_escape(line) |> Phoenix.HTML.safe_to_string()
      "<p>#{escaped}</p>" <> text
    end
  end
end
