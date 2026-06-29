defmodule LeythersCom.Ingestion.SourceLinkHealthCheckerTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.SourceLinkHealthChecker

  defmodule OkClient do
    def probe(_url) do
      {:ok, %{status: 200, headers: %{}, body: "<html></html>"}}
    end
  end

  defmodule RedirectClient do
    def probe(_url) do
      {:ok,
       %{
         status: 301,
         headers: %{"location" => ["https://example.com/leigh-win?utm_source=feed"]},
         body: ""
       }}
    end
  end

  defmodule BrokenClient do
    def probe(_url), do: {:error, :timeout}
  end

  defmodule BulkClient do
    def probe("https://example.com/leigh-win") do
      {:ok, %{status: 200, headers: %{}, body: "<html></html>"}}
    end

    def probe("https://example.com/leigh-win-2") do
      {:ok,
       %{
         status: 301,
         headers: %{"location" => ["https://example.com/leigh-win-2?utm_source=feed"]},
         body: ""
       }}
    end
  end

  test "check_raw_source/2 marks a healthy source ok" do
    {:ok, source} =
      Ingestion.create_raw_source(%{
        title: "Leigh Leopards",
        url: "https://example.com/leigh-win",
        origin_provider: "bbc_sport",
        external_published_at: ~U[2026-06-01 10:00:00.000000Z]
      })

    {:ok, updated_source} = SourceLinkHealthChecker.check_raw_source(source, OkClient)

    assert updated_source.last_check_status == "ok"
    assert updated_source.url == "https://example.com/leigh-win"
    assert updated_source.last_checked_at
  end

  test "check_raw_source/2 follows redirects and canonicalizes the target" do
    {:ok, source} =
      Ingestion.create_raw_source(%{
        title: "Leigh Leopards",
        url: "https://example.com/leigh-win",
        origin_provider: "bbc_sport",
        external_published_at: ~U[2026-06-01 10:00:00.000000Z]
      })

    {:ok, updated_source} = SourceLinkHealthChecker.check_raw_source(source, RedirectClient)

    assert updated_source.last_check_status == "redirected"
    assert updated_source.url == "https://example.com/leigh-win"
  end

  test "check_raw_source/2 marks failures broken" do
    {:ok, source} =
      Ingestion.create_raw_source(%{
        title: "Leigh Leopards",
        url: "https://example.com/leigh-win",
        origin_provider: "bbc_sport",
        external_published_at: ~U[2026-06-01 10:00:00.000000Z]
      })

    {:ok, updated_source} = SourceLinkHealthChecker.check_raw_source(source, BrokenClient)

    assert updated_source.last_check_status == "broken"
    assert updated_source.url == "https://example.com/leigh-win"
  end

  test "check_all_raw_sources/1 checks every raw source" do
    {:ok, source_a} =
      Ingestion.create_raw_source(%{
        title: "Leigh Leopards One",
        url: "https://example.com/leigh-win",
        origin_provider: "bbc_sport",
        external_published_at: ~U[2026-06-01 10:00:00.000000Z]
      })

    {:ok, source_b} =
      Ingestion.create_raw_source(%{
        title: "Leigh Leopards Two",
        url: "https://example.com/leigh-win-2",
        origin_provider: "bbc_sport",
        external_published_at: ~U[2026-06-01 11:00:00.000000Z]
      })

    assert :ok = SourceLinkHealthChecker.check_all_raw_sources(BulkClient)

    assert Ingestion.get_raw_source!(source_a.id).last_check_status == "ok"
    assert Ingestion.get_raw_source!(source_b.id).last_check_status == "redirected"
    assert Ingestion.get_raw_source!(source_b.id).url == "https://example.com/leigh-win-2"
  end
end
