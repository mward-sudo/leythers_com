defmodule LeythersCom.Ingestion.Providers.HtmlTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Ingestion.Providers.Html

  test "normalize/1 extracts metadata from html" do
    attrs = %{
      html: """
      <html>
        <head>
          <meta property="og:title" content=" Leigh Leopards Claim Victory "/>
          <meta name="description" content=" A late try sealed the win. "/>
        </head>
        <body>
          <h1>Ignored heading</h1>
          <p>First paragraph summary.</p>
        </body>
      </html>
      """,
      url: "https://example.com/leigh-win?utm_campaign=social",
      origin_provider: "  bbc_sport  "
    }

    assert %{
             "title" => "Leigh Leopards Claim Victory",
             "body_summary" => "A late try sealed the win.",
             "url" => "https://example.com/leigh-win",
             "origin_provider" => "bbc_sport"
           } = Html.normalize(attrs)
  end

  test "normalize/1 falls back to title and paragraph text" do
    attrs = %{
      html: """
      <html>
        <head>
          <title> Match Report </title>
        </head>
        <body>
          <p>  This is the opening paragraph.  </p>
        </body>
      </html>
      """
    }

    assert %{"title" => "Match Report", "body_summary" => "This is the opening paragraph."} =
             Html.normalize(attrs)
  end
end
