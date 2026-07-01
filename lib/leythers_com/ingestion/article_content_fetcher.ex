defmodule LeythersCom.Ingestion.ArticleContentFetcher do
  @moduledoc """
  Fetches and extracts HTML content from article URLs.
  Stores full article content for LLM processing.
  """

  @timeout_ms 15_000
  # 2MB limit
  @max_content_size 2_000_000
  @user_agent "Mozilla/5.0 (compatible; LeythersCom/1.0)"

  def fetch_and_extract(url) when is_binary(url) do
    with {:ok, response} <- fetch_url(url),
         :ok <- validate_content_type(response),
         :ok <- validate_content_size(response),
         content <- extract_article_content(response.body) do
      {:ok, content}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_and_extract(_), do: {:error, :invalid_url}

  # ── Private Helpers ───────────────────────────────────────────────────────

  defp fetch_url(url) do
    case Req.get(url,
           timeout: @timeout_ms,
           headers: [{"user-agent", @user_agent}],
           follow_redirects: true,
           max_redirects: 5
         ) do
      {:ok, response} ->
        if response.status == 200 do
          {:ok, response}
        else
          {:error, {:http_error, response.status}}
        end

      {:error, reason} ->
        {:error, {:fetch_failed, inspect(reason)}}
    end
  rescue
    _ -> {:error, :fetch_exception}
  end

  defp validate_content_type(response) do
    case response.headers["content-type"] do
      nil ->
        :ok

      content_type when is_binary(content_type) ->
        normalized = String.downcase(content_type)

        if String.contains?(normalized, ["text/html", "application/xhtml"]) do
          :ok
        else
          {:error, {:unsupported_content_type, content_type}}
        end

      _ ->
        :ok
    end
  end

  defp validate_content_size(response) do
    case byte_size(response.body) do
      size when size > @max_content_size ->
        {:error, {:content_too_large, size}}

      _size ->
        :ok
    end
  end

  defp extract_article_content(html_body) when is_binary(html_body) do
    html_body
    |> extract_main_content()
    |> strip_html_tags()
    |> normalize_whitespace()
  end

  defp extract_main_content(html) do
    patterns = [
      ~r/<article[^>]*>(.*?)<\/article>/is,
      ~r/<main[^>]*>(.*?)<\/main>/is,
      ~r/<div[^>]*class="[^"]*content[^"]*"[^>]*>(.*?)<\/div>/is,
      ~r/<div[^>]*class="[^"]*article[^"]*"[^>]*>(.*?)<\/div>/is,
      ~r/<div[^>]*class="[^"]*post[^"]*"[^>]*>(.*?)<\/div>/is
    ]

    case find_pattern_match(patterns, html) do
      nil -> html
      content -> content
    end
  end

  defp find_pattern_match([], _html), do: nil

  defp find_pattern_match([pattern | rest], html) do
    case Regex.run(pattern, html) do
      [_, content] -> content
      _ -> find_pattern_match(rest, html)
    end
  end

  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<[^>]+>/u, " ")
    |> String.replace(~r/&nbsp;/i, " ")
    |> String.replace(~r/&lt;/i, "<")
    |> String.replace(~r/&gt;/i, ">")
    |> String.replace(~r/&amp;/i, "&")
    |> String.replace(~r/&quot;/i, "\"")
    |> String.replace(~r/&#39;/i, "'")
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\n\n+/, "\n\n")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim()
  end
end
