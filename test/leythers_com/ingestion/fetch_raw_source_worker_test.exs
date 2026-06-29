defmodule LeythersCom.Ingestion.FetchRawSourceWorkerTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.FetchRawSourceWorker

  defmodule FakeHttpClient do
    def fetch(_url) do
      {:ok,
       """
       <html>
         <head>
           <meta property=\"og:title\" content=\" Leigh Leopards do it again \" />
           <meta name=\"description\" content=\" Another clinical display. \" />
         </head>
       </html>
       """}
    end
  end

  test "fetch_and_upsert/2 fetches html and persists normalized attrs" do
    assert :ok =
             FetchRawSourceWorker.fetch_and_upsert(
               %{
                 "url" => "https://example.com/leigh-win?utm_source=feed",
                 "origin_provider" => "bbc_sport"
               },
               FakeHttpClient
             )

    [source] = Ingestion.list_raw_sources()
    assert source.url == "https://example.com/leigh-win"
    assert source.title == "Leigh Leopards do it again"
    assert source.body_summary == "Another clinical display."
  end

  test "fetch_and_upsert/2 handles already-fetched html payloads" do
    assert :ok =
             FetchRawSourceWorker.fetch_and_upsert(
               %{
                 "html" => "<html><head><title>Direct HTML</title></head></html>",
                 "url" => "https://example.com/direct-html",
                 "origin_provider" => "manual_admin"
               },
               FakeHttpClient
             )

    [source] = Ingestion.list_raw_sources()
    assert source.title == "Direct HTML"
    assert source.url == "https://example.com/direct-html"
  end
end
