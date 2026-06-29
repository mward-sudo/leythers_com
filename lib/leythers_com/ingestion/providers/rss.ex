defmodule LeythersCom.Ingestion.Providers.Rss do
  @moduledoc """
  RSS/Atom feed parser that extracts normalized raw-source attrs.
  """

  alias LeythersCom.Ingestion.Providers.Basic

  def parse_items(feed_body, origin_provider, fallback_url \\ nil)

  def parse_items(feed_body, origin_provider, fallback_url)
      when is_binary(feed_body) and is_binary(origin_provider) do
    normalized_provider = String.trim(origin_provider)

    feed_body
    |> extract_entries()
    |> Enum.map(&entry_to_attrs(&1, normalized_provider, fallback_url))
    |> Enum.reject(&is_nil/1)
  end

  def parse_items(_feed_body, _origin_provider, _fallback_url), do: []

  defp extract_entries(feed_body) do
    item_entries = Regex.scan(~r/<item\b[^>]*>(.*?)<\/item>/ms, feed_body)

    if item_entries != [] do
      Enum.map(item_entries, fn [_, body] -> body end)
    else
      Regex.scan(~r/<entry\b[^>]*>(.*?)<\/entry>/ms, feed_body)
      |> Enum.map(fn [_, body] -> body end)
    end
  end

  defp entry_to_attrs(entry_body, origin_provider, fallback_url) do
    title = extract_tag_text(entry_body, "title")
    url = extract_url(entry_body) || fallback_url

    if blank?(title) or blank?(url) do
      nil
    else
      body_summary =
        extract_tag_text(entry_body, "description") ||
          extract_tag_text(entry_body, "summary") ||
          extract_tag_text(entry_body, "content")

      external_published_at =
        extract_tag_text(entry_body, "pubDate") ||
          extract_tag_text(entry_body, "published") ||
          extract_tag_text(entry_body, "updated")

      %{
        "title" => title,
        "url" => url,
        "body_summary" => body_summary,
        "origin_provider" => origin_provider,
        "external_published_at" => parse_datetime(external_published_at)
      }
      |> Basic.normalize()
    end
  end

  defp extract_url(entry_body) do
    extract_tag_text(entry_body, "link") || extract_atom_link_href(entry_body)
  end

  defp extract_atom_link_href(entry_body) do
    case Regex.run(~r/<link\b[^>]*href=["']([^"']+)["'][^>]*\/?>(?:<\/link>)?/i, entry_body) do
      [_, href] -> String.trim(href)
      _ -> nil
    end
  end

  defp extract_tag_text(entry_body, tag_name) do
    regex = ~r/<#{tag_name}\b[^>]*>(.*?)<\/#{tag_name}>/mis

    case Regex.run(regex, entry_body) do
      [_, content] -> content |> strip_cdata() |> strip_html() |> normalize_text()
      _ -> nil
    end
  end

  defp strip_cdata(content) do
    content
    |> String.replace(~r/^<!\[CDATA\[/, "")
    |> String.replace(~r/\]\]>$/, "")
  end

  defp strip_html(content) do
    case Floki.parse_fragment(content) do
      {:ok, fragment} -> Floki.text(fragment, sep: " ")
      _ -> content
    end
  end

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_text(_), do: nil

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(value) when is_binary(value) do
    trimmed = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(trimmed),
         erlang_datetime when erlang_datetime != :bad_date <-
           :httpd_util.convert_request_date(String.to_charlist(trimmed)) do
      erlang_datetime
      |> NaiveDateTime.from_erl!()
      |> DateTime.from_naive!("Etc/UTC")
    else
      {:ok, datetime, _offset} -> datetime
      :bad_date -> DateTime.utc_now()
    end
  rescue
    _ -> DateTime.utc_now()
  end

  defp blank?(value), do: value in [nil, ""]
end
