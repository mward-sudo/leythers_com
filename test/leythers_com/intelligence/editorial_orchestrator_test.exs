defmodule LeythersCom.Intelligence.EditorialOrchestratorTest do
  use LeythersCom.DataCase, async: false

  import Ecto.Query

  alias LeythersCom.Content
  alias LeythersCom.Content.ArticleSource
  alias LeythersCom.Ingestion
  alias LeythersCom.Intelligence.EditorialOrchestrator
  alias LeythersCom.Intelligence.HomepageRankingDecision

  @article_attrs %{
    title: "Leigh Leopards Build Midfield Pressure",
    body: "Terrace chatter says the shape looked sharper.",
    author_type: "ai_editor",
    status: "published"
  }

  @source_attrs %{
    title: "Source headline",
    url: "https://example.com/source",
    origin_provider: "bbc_sport",
    external_published_at: ~U[2026-06-29 09:00:00.000000Z]
  }

  setup do
    EditorialOrchestrator.clear_trigger_cache!()
    :ok
  end

  test "refresh_homepage_layout/1 persists a decision snapshot" do
    _article =
      insert_article_with_source("leythers-refresh-one", "https://example.com/source-one")

    _other_article =
      insert_article_with_source("leythers-refresh-two", "https://example.com/source-two")

    assert {:ok, %{run_id: run_id, decision_count: 2}} =
             EditorialOrchestrator.refresh_homepage_layout(
               llm_enabled: false,
               source_limit: 10,
               homepage_size: 2,
               prompt_version: "homepage_ranker_test"
             )

    decisions =
      HomepageRankingDecision
      |> where([decision], decision.run_id == ^run_id)
      |> order_by([decision], asc: decision.rank_position)
      |> Repo.all()

    assert length(decisions) == 2
    assert Enum.map(decisions, & &1.rank_position) == [1, 2]
    assert Enum.all?(decisions, &(&1.prompt_version == "homepage_ranker_test"))

    snapshot = EditorialOrchestrator.latest_homepage_snapshot(2)
    assert length(snapshot) == 2
    assert Enum.all?(snapshot, &is_map(&1.article))
  end

  test "trigger_source_update_refresh/1 enforces cooldown" do
    assert {:ok, %{decision_count: 0}} =
             EditorialOrchestrator.trigger_source_update_refresh(
               llm_enabled: false,
               refresh_cooldown_seconds: 3600
             )

    assert {:ok, :cooldown} =
             EditorialOrchestrator.trigger_source_update_refresh(
               llm_enabled: false,
               refresh_cooldown_seconds: 3600
             )
  end

  defp insert_article_with_source(slug, source_url) do
    {:ok, article} = Content.create_article(Map.put(@article_attrs, :slug, slug))

    {:ok, source} =
      @source_attrs
      |> Map.put(:url, source_url)
      |> Ingestion.create_raw_source()

    {:ok, _link} =
      %ArticleSource{}
      |> ArticleSource.changeset(%{permanent_article_id: article.id, raw_source_id: source.id})
      |> Repo.insert()

    article
  end
end
