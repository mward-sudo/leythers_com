defmodule LeythersCom.Ingestion.FetchRssFeedWorkerTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Ingestion

  defmodule FakeFeedClient do
    def fetch(_url) do
      {:ok,
       """
       <rss version=\"2.0\">
         <channel>
           <item>
             <title>Leigh first story</title>
             <link>https://example.com/story-1?utm_source=rss</link>
             <description>First summary</description>
             <pubDate>Mon, 29 Jun 2026 10:00:00 GMT</pubDate>
           </item>
           <item>
             <title>Leigh second story</title>
             <link>https://example.com/story-2?utm_source=rss</link>
             <description>Second summary</description>
             <pubDate>Mon, 29 Jun 2026 11:00:00 GMT</pubDate>
           </item>
         </channel>
       </rss>
       """}
    end
  end

  test "ingest_rss_feed/2 fetches and upserts feed entries" do
    assert {:ok, %{processed: 2, inserted: 2, errors: 0}} =
             Ingestion.ingest_rss_feed(
               %{
                 "url" => "https://example.com/feed.xml",
                 "origin_provider" => "bbc_rugby_league"
               },
               FakeFeedClient
             )

    sources = Ingestion.list_raw_sources()
    assert length(sources) == 2
    assert Enum.any?(sources, &(&1.url == "https://example.com/story-1"))
    assert Enum.any?(sources, &(&1.url == "https://example.com/story-2"))
  end

  test "ingest_rss_feed/2 returns config errors for missing attrs" do
    assert {:error, :missing_url} =
             Ingestion.ingest_rss_feed(%{"origin_provider" => "bbc_rugby_league"}, FakeFeedClient)

    assert {:error, :missing_origin_provider} =
             Ingestion.ingest_rss_feed(%{"url" => "https://example.com/feed.xml"}, FakeFeedClient)
  end
end
