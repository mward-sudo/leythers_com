defmodule LeythersCom.Content.Voice do
  @moduledoc """
  Deterministic editorial voice transforms used to keep generated output
  consistent while minimizing extra model usage.
  """

  @voice_config_key :voice_profile

  def profile do
    Application.get_env(:leythers_com, @voice_config_key, [])
  end

  def apply(%{title: title, body: body}, opts \\ []) do
    rumour? = Keyword.get(opts, :rumour, false)
    profile = Keyword.get(opts, :profile, profile())

    %{
      title: style_title(title, rumour?, profile),
      body: style_body(body, rumour?, profile)
    }
  end

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
    body = String.trim(body)

    rumour_notice =
      profile[:rumour_notice] || "Rumour mill warning: treat this as chatter until confirmed."

    fan_signoff =
      profile[:fan_signoff] || "Terrace verdict: proper Leythers chaos, and we love it."

    base_body =
      if rumour? do
        prepend_line_unless_present(body, rumour_notice)
      else
        body
      end

    append_line_unless_present(base_body, fan_signoff)
  end

  defp style_body(_body, rumour?, profile) do
    style_body("", rumour?, profile)
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
