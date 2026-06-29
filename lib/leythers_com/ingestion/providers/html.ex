defmodule LeythersCom.Ingestion.Providers.Html do
  @moduledoc """
  HTML provider adapter for extracted page metadata.
  """

  @behaviour LeythersCom.Ingestion.Provider

  alias LeythersCom.Ingestion.Providers.Basic

  @impl true
  def normalize(attrs) when is_map(attrs) do
    attrs
    |> Basic.normalize()
    |> put_title()
    |> put_body_summary()
    |> Map.delete(:html)
    |> Map.delete("html")
  end

  defp put_title(attrs) do
    maybe_put(attrs, :title, fn html ->
      html
      |> first_text([
        ~s(meta[property="og:title"]),
        "title",
        "h1"
      ])
    end)
  end

  defp put_body_summary(attrs) do
    maybe_put(attrs, :body_summary, fn html ->
      html
      |> first_text([
        ~s(meta[name="description"]),
        "p"
      ])
    end)
  end

  defp maybe_put(attrs, key, extractor) do
    case Map.get(attrs, :html) || Map.get(attrs, "html") do
      html when is_binary(html) ->
        value = html |> extractor.() |> normalize_text()

        if value == nil do
          attrs
        else
          Map.put(attrs, key, value)
        end

      _ ->
        attrs
    end
  end

  defp first_text(html, selectors) do
    with {:ok, document} <- Floki.parse_document(html) do
      selectors
      |> Enum.find_value(fn selector ->
        document
        |> Floki.find(selector)
        |> extract_selector_text(selector)
      end)
    else
      _ -> nil
    end
  end

  defp extract_selector_text([], _selector), do: nil

  defp extract_selector_text(elements, selector) do
    if String.starts_with?(selector, "meta[") do
      elements
      |> List.first()
      |> Floki.attribute("content")
      |> List.first()
      |> normalize_text()
    else
      elements
      |> Floki.text(sep: " ")
      |> normalize_text()
    end
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end
end
