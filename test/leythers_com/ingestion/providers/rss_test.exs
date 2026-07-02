defmodule LeythersCom.Ingestion.Providers.RssTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Ingestion.Providers.Rss

  test "parse_items/3 extracts normalized attrs from RSS item entries" do
    feed = """
    <rss version=\"2.0\">
      <channel>
        <item>
          <title> Leigh Leopards edge tense contest </title>
          <link>https://example.com/report?utm_source=rss</link>
          <description><![CDATA[ <p>Late drama at the LSV.</p> ]]></description>
          <pubDate>Mon, 29 Jun 2026 09:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
    """

    [item] = Rss.parse_items(feed, "bbc_rugby_league")

    assert item["title"] == "Leigh Leopards edge tense contest"
    assert item["url"] == "https://example.com/report"
    assert item["body_summary"] == "Late drama at the LSV."
    assert item["origin_provider"] == "bbc_rugby_league"
    assert %DateTime{} = item["external_published_at"]
  end

  test "parse_items/3 supports Atom entries with href links" do
    feed = """
    <feed xmlns=\"http://www.w3.org/2005/Atom\">
      <entry>
        <title>Leigh squad update</title>
        <link href=\"https://example.com/atom-story?ref=feed\" />
        <summary>Selection notes.</summary>
        <updated>2026-06-29T10:45:00Z</updated>
      </entry>
    </feed>
    """

    [item] = Rss.parse_items(feed, "atom_feed")

    assert item["title"] == "Leigh squad update"
    assert item["url"] == "https://example.com/atom-story"
    assert item["body_summary"] == "Selection notes."
    assert item["origin_provider"] == "atom_feed"
    assert %DateTime{} = item["external_published_at"]
  end

  test "parse_items/3 prefers external publisher href for Google News links" do
    feed = """
    <rss version=\"2.0\">
      <channel>
        <item>
          <title>Leigh transfer latest</title>
          <link>https://news.google.com/rss/articles/abc123?oc=5</link>
          <description><![CDATA[
            <a href=\"https://news.google.com/rss/articles/abc123?oc=5\">Google</a>
            <a href=\"https://www.loverugbyleague.com/post/leigh-transfer-latest\">Publisher</a>
          ]]></description>
          <pubDate>Mon, 29 Jun 2026 12:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
    """

    [item] = Rss.parse_items(feed, "google_news_leigh_leopards")

    assert item["url"] == "https://www.loverugbyleague.com/post/leigh-transfer-latest"
  end
end
