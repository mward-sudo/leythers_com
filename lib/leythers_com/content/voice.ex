defmodule LeythersCom.Content.Voice do
  @moduledoc """
  Deterministic editorial voice transforms used to keep generated output
  consistent while minimizing extra model usage.
  """

  @fan_signoff "Terrace verdict: proper Leythers chaos, and we love it."
  @rumour_notice "Rumour mill warning: treat this as chatter until confirmed."

  def apply(%{title: title, body: body}, opts \\ []) do
    rumour? = Keyword.get(opts, :rumour, false)

    %{
      title: style_title(title, rumour?),
      body: style_body(body, rumour?)
    }
  end

  defp style_title(title, true) when is_binary(title) do
    trimmed = String.trim(title)

    if String.starts_with?(String.downcase(trimmed), "rumour:") do
      trimmed
    else
      "Rumour: " <> trimmed
    end
  end

  defp style_title(title, false) when is_binary(title), do: String.trim(title)

  defp style_body(body, rumour?) when is_binary(body) do
    body = String.trim(body)

    base_body =
      if rumour? do
        prepend_line_unless_present(body, @rumour_notice)
      else
        body
      end

    append_line_unless_present(base_body, @fan_signoff)
  end

  defp style_body(_body, rumour?) do
    style_body("", rumour?)
  end

  defp prepend_line_unless_present(text, line) do
    if String.contains?(String.downcase(text), String.downcase(line)) do
      text
    else
      line <> "\n\n" <> text
    end
  end

  defp append_line_unless_present(text, line) do
    if String.contains?(String.downcase(text), String.downcase(line)) do
      text
    else
      text <> "\n\n" <> line
    end
  end
end
