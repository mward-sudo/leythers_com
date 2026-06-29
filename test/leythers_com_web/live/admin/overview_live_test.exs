defmodule LeythersComWeb.Admin.OverviewLiveTest do
  use LeythersComWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LeythersCom.Content
  alias LeythersCom.Ingestion
  alias LeythersCom.Intelligence

  describe "authentication" do
    test "redirects unauthenticated users to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/overview")
      assert path =~ "/users/log-in"
    end
  end

  describe "index/0" do
    setup :register_and_log_in_user

    test "renders budget summary and provenance data", %{conn: conn, user: _user} do
      {:ok, source} =
        Ingestion.create_raw_source(%{
          title: "Overview Test Source",
          url: "https://example.com/overview-test-source",
          origin_provider: "rss",
          external_published_at: ~U[2026-06-21 10:00:00.000000Z]
        })

      {:ok, _article} =
        Content.publish_article(
          %{
            title: "Overview Test Article",
            body: "Overview body"
          },
          [source.id]
        )

      {:ok, _ledger} =
        Intelligence.upsert_cost_ledger(%{
          date: Date.utc_today(),
          input_tokens: 123,
          output_tokens: 45,
          estimated_cost_gbp: Decimal.new("1.230000")
        })

      {:ok, view, html} = live(conn, ~p"/admin/overview")

      assert html =~ "Admin Overview"
      assert has_element?(view, "#budget-summary")
      assert has_element?(view, "#cost-history")
      assert has_element?(view, "#provenance-history")
      assert has_element?(view, "#provenance-history", "Overview Test Article")
      assert has_element?(view, "#provenance-history", "Overview Test Source")
      assert has_element?(view, "#cost-history", "1.230000")
    end
  end
end
