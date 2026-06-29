defmodule LeythersCom.IngestionTest do
  use LeythersCom.DataCase, async: true

  alias Ecto.UUID
  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.RawSource

  @valid_attrs %{
    title: "Leigh Leopards win again",
    url: "https://example.com/leigh-win",
    origin_provider: "bbc_sport",
    external_published_at: ~U[2026-06-01 10:00:00.000000Z]
  }

  describe "create_raw_source/1" do
    test "inserts a valid raw source" do
      assert {:ok, %RawSource{} = source} = Ingestion.create_raw_source(@valid_attrs)
      assert source.title == "Leigh Leopards win again"
      assert source.status == "pending"
    end

    test "returns error changeset for missing required fields" do
      assert {:error, %Ecto.Changeset{}} = Ingestion.create_raw_source(%{})
    end

    test "returns error changeset on duplicate url" do
      {:ok, _} = Ingestion.create_raw_source(@valid_attrs)
      assert {:error, %Ecto.Changeset{}} = Ingestion.create_raw_source(@valid_attrs)
    end

    test "accepts long feed URLs used by news aggregators" do
      long_url =
        "https://news.google.com/rss/articles/" <>
          String.duplicate("a", 280)

      attrs = Map.put(@valid_attrs, :url, long_url)

      assert {:ok, %RawSource{} = source} = Ingestion.create_raw_source(attrs)
      assert source.url == long_url
    end
  end

  describe "upsert_raw_source/1" do
    test "inserts when url is new" do
      assert {:ok, %RawSource{}} = Ingestion.upsert_raw_source(@valid_attrs)
    end

    test "triggers editorial orchestration refresh telemetry" do
      handler_id = "ingestion-editorial-trigger-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:leythers_com, :intelligence, :editorial_orchestration, :stop],
          fn event, measurements, metadata, test_pid ->
            send(test_pid, {:telemetry_event, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %RawSource{}} = Ingestion.upsert_raw_source(@valid_attrs)

      assert_receive {:telemetry_event,
                      [:leythers_com, :intelligence, :editorial_orchestration, :stop],
                      measurements, metadata}

      assert measurements.count == 1
      assert measurements.duration > 0
      assert metadata.result == :ok
      assert metadata.triggered_by == :source_update
    end

    test "returns existing record unchanged when url already exists" do
      {:ok, original} = Ingestion.upsert_raw_source(@valid_attrs)

      updated_attrs = Map.put(@valid_attrs, :title, "Updated Title")
      {:ok, result} = Ingestion.upsert_raw_source(updated_attrs)

      assert result.id == original.id
      assert result.title == original.title
    end

    test "canonicalizes tracking parameters before deduping" do
      attrs_with_tracking =
        Map.put(
          @valid_attrs,
          :url,
          "https://example.com/leigh-win?utm_source=newsletter&ref=homepage"
        )

      assert {:ok, %RawSource{} = first_source} = Ingestion.upsert_raw_source(attrs_with_tracking)

      refetched = Repo.get!(RawSource, first_source.id)
      assert refetched.url == "https://example.com/leigh-win"

      duplicate_attrs =
        Map.put(@valid_attrs, :title, "Different title")
        |> Map.put(:url, "https://example.com/leigh-win?ref=sidebar&utm_medium=email")

      assert {:ok, %RawSource{} = second_source} = Ingestion.upsert_raw_source(duplicate_attrs)

      assert second_source.id == first_source.id
      assert second_source.title == first_source.title
      assert second_source.url == first_source.url
    end
  end

  describe "get_raw_source!/1" do
    test "returns the raw source for a given id" do
      {:ok, source} = Ingestion.create_raw_source(@valid_attrs)
      assert Ingestion.get_raw_source!(source.id).id == source.id
    end

    test "raises for unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        Ingestion.get_raw_source!(UUID.generate())
      end
    end
  end

  describe "record_raw_source_health/2" do
    test "updates health fields on an existing source" do
      {:ok, source} = Ingestion.create_raw_source(@valid_attrs)

      {:ok, updated_source} =
        Ingestion.record_raw_source_health(source, %{
          last_checked_at: ~U[2026-06-29 12:00:00.000000Z],
          last_check_status: "ok"
        })

      assert updated_source.last_checked_at == ~U[2026-06-29 12:00:00.000000Z]
      assert updated_source.last_check_status == "ok"
      assert updated_source.id == source.id
    end

    test "canonicalizes redirected urls before persisting" do
      {:ok, source} = Ingestion.create_raw_source(@valid_attrs)

      {:ok, updated_source} =
        Ingestion.record_raw_source_health(source, %{
          last_checked_at: ~U[2026-06-29 12:00:00.000000Z],
          last_check_status: "redirected",
          url: "https://example.com/leigh-win?utm_medium=email&gclid=abc123"
        })

      assert updated_source.last_check_status == "redirected"
      assert updated_source.url == "https://example.com/leigh-win"
    end
  end

  describe "ingest_rss_feed/2" do
    defmodule FeedClient do
      def fetch(_url) do
        {:ok,
         """
         <rss version=\"2.0\">
           <channel>
             <item>
               <title>Leigh item one</title>
               <link>https://example.com/leigh-item-one</link>
               <description>One summary</description>
               <pubDate>Mon, 29 Jun 2026 10:00:00 GMT</pubDate>
             </item>
           </channel>
         </rss>
         """}
      end
    end

    test "emits feed ingest telemetry with provider metadata" do
      handler_id = "ingestion-feed-ingest-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:leythers_com, :ingestion, :feed_ingest, :stop],
          fn event, measurements, metadata, test_pid ->
            send(test_pid, {:telemetry_event, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{processed: 1, inserted: 1, errors: 0}} =
               Ingestion.ingest_rss_feed(
                 %{
                   "url" => "https://example.com/feed.xml",
                   "origin_provider" => "telemetry_provider"
                 },
                 FeedClient
               )

      assert_receive {:telemetry_event, [:leythers_com, :ingestion, :feed_ingest, :stop],
                      measurements, metadata}

      assert measurements.duration > 0
      assert measurements.count == 1
      assert metadata.result == :ok
      assert metadata.origin_provider == "telemetry_provider"
      assert metadata.processed == 1
      assert metadata.inserted == 1
      assert metadata.errors == 0
    end
  end

  describe "feed_freshness_report/1" do
    test "reports stale and fresh providers" do
      {:ok, _fresh_source} =
        Ingestion.create_raw_source(%{
          title: "Recent source",
          url: "https://example.com/fresh-source",
          origin_provider: "fresh_provider",
          external_published_at: DateTime.utc_now()
        })

      report =
        Ingestion.feed_freshness_report(
          origin_providers: ["fresh_provider", "stale_provider"],
          stale_after_hours: 1
        )

      fresh = Enum.find(report, &(&1.origin_provider == "fresh_provider"))
      stale = Enum.find(report, &(&1.origin_provider == "stale_provider"))

      assert fresh.stale == false
      assert is_integer(fresh.age_seconds)
      assert %DateTime{} = fresh.last_seen_at

      assert stale.stale == true
      assert stale.age_seconds == nil
      assert stale.last_seen_at == nil
    end
  end
end
