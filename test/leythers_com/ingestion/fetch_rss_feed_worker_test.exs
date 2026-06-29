defmodule LeythersCom.Ingestion.FetchRssFeedWorkerTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.FetchRssFeedWorker
  alias LeythersCom.Intelligence

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

  test "ingest_rss_feed/2 filters feed entries by include_keywords" do
    assert {:ok, %{processed: 1, inserted: 1, errors: 0}} =
             Ingestion.ingest_rss_feed(
               %{
                 "url" => "https://example.com/feed.xml",
                 "origin_provider" => "bbc_rugby_league",
                 "include_keywords" => ["second"]
               },
               FakeFeedClient
             )

    [source] = Ingestion.list_raw_sources()
    assert source.title == "Leigh second story"
    assert source.url == "https://example.com/story-2"
  end

  test "ingest_rss_feed/2 returns config errors for missing attrs" do
    assert {:error, :missing_url} =
             Ingestion.ingest_rss_feed(%{"origin_provider" => "bbc_rugby_league"}, FakeFeedClient)

    assert {:error, :missing_origin_provider} =
             Ingestion.ingest_rss_feed(%{"url" => "https://example.com/feed.xml"}, FakeFeedClient)
  end

  describe "backoff/1" do
    test "applies exponential retry backoff from configured base" do
      job = %Oban.Job{attempt: 3, args: %{}}
      assert FetchRssFeedWorker.backoff(job) == 240
    end

    test "applies provider-specific multiplier when configured" do
      job = %Oban.Job{attempt: 2, args: %{"origin_provider" => "google_news_leigh_leopards"}}
      assert FetchRssFeedWorker.backoff(job) == 240
    end

    test "caps delay at configured max" do
      job = %Oban.Job{attempt: 12, args: %{"origin_provider" => "google_news_leigh_leopards"}}
      assert FetchRssFeedWorker.backoff(job) == 1800
    end
  end

  test "perform/1 records a retryable job effect event when feed attrs are invalid" do
    job = %Oban.Job{
      id: 901,
      args: %{"origin_provider" => "bbc_rugby_league"},
      worker: "LeythersCom.Ingestion.FetchRssFeedWorker",
      queue: "ingestion",
      attempt: 1
    }

    assert {:error, _reason} = FetchRssFeedWorker.perform(job)

    [event | _] = Intelligence.job_effect_events_for_job(901)
    assert event.decision_action == "skipped_publish_error"
    assert event.state == "retryable"
    assert event.worker == "LeythersCom.Ingestion.FetchRssFeedWorker"
    assert event.queue == "ingestion"
  end
end
