defmodule LeythersCom.Ingestion.Providers.BasicTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Ingestion.Providers.Basic

  test "normalize/1 trims strings and strips tracking params" do
    attrs = %{
      title: "  Leigh Leopards win  ",
      body_summary: "  Big match  ",
      origin_provider: "  bbc_sport  ",
      url: "https://example.com/leigh-win?utm_source=newsletter&ref=homepage"
    }

    assert %{
             "title" => "Leigh Leopards win",
             "body_summary" => "Big match",
             "origin_provider" => "bbc_sport",
             "url" => "https://example.com/leigh-win"
           } = Basic.normalize(attrs)
  end

  test "normalize/1 handles string keys" do
    attrs = %{
      "title" => "  Leigh Leopards win  ",
      "url" => "https://example.com/leigh-win?gclid=abc123"
    }

    assert %{"title" => "Leigh Leopards win", "url" => "https://example.com/leigh-win"} =
             Basic.normalize(attrs)
  end
end
