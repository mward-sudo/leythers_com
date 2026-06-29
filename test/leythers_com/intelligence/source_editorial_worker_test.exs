defmodule LeythersCom.Intelligence.SourceEditorialWorkerTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Content
  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.ArticleGenerationDecision
  alias LeythersCom.Intelligence.SourceEditorialWorker

  setup do
    original_generation_config = Application.get_env(:leythers_com, :intelligence_generation)

    on_exit(fn ->
      Application.put_env(:leythers_com, :intelligence_generation, original_generation_config)
    end)

    Application.put_env(:leythers_com, :intelligence_generation,
      auto_generation_enabled: true,
      source_batch_size: 20,
      max_batches_per_run: 20,
      significance_threshold: 70,
      prompt_version: "source_editorial_test",
      llm_draft_enabled: false,
      llm_cost_per_1k_tokens_gbp: "0.000000"
    )

    :ok
  end

  test "publishes AI article from pending sources and marks them processed" do
    {:ok, source_one} =
      Ingestion.create_raw_source(%{
        title: "Leigh confirm squad update ahead of weekend",
        url: "https://example.com/squad-update-1",
        body_summary: "Key players return ahead of the weekend fixture.",
        origin_provider: "test_feed",
        external_published_at: ~U[2026-06-29 09:00:00.000000Z]
      })

    {:ok, source_two} =
      Ingestion.create_raw_source(%{
        title: "Leigh confirm squad update ahead of derby",
        url: "https://example.com/squad-update-2",
        body_summary: "Training ground reports point to stronger bench options.",
        origin_provider: "test_feed",
        external_published_at: ~U[2026-06-29 10:00:00.000000Z]
      })

    assert :ok = SourceEditorialWorker.perform(%Oban.Job{args: %{}})

    ai_articles = Content.list_articles() |> Enum.filter(&(&1.author_type == "ai_editor"))
    assert length(ai_articles) == 1

    [article] = ai_articles
    assert article.title =~ "Leigh confirm squad update"
    assert article.body =~ "Automated feed digest"
    assert article.status == "published"

    [decision] = Intelligence.recent_article_generation_decisions(1)
    assert %ArticleGenerationDecision{} = decision
    assert decision.decision_action == "created"
    assert decision.source_count == 2
    assert decision.prompt_version == "source_editorial_test"
    assert decision.permanent_article_id == article.id

    assert %RawSource{status: "processed"} = Repo.get!(RawSource, source_one.id)
    assert %RawSource{status: "processed"} = Repo.get!(RawSource, source_two.id)
  end

  test "skips generation when budget is over cap" do
    assert {:ok, _source} =
             Ingestion.create_raw_source(%{
               title: "Leigh transfer rumour gains pace",
               url: "https://example.com/transfer-rumour-1",
               body_summary: "Talks continue with an overseas halfback.",
               origin_provider: "test_feed",
               external_published_at: ~U[2026-06-29 11:00:00.000000Z]
             })

    {:ok, _ledger} =
      Intelligence.upsert_cost_ledger(%{
        date: Date.utc_today(),
        input_tokens: 1,
        output_tokens: 1,
        estimated_cost_gbp: Decimal.new("20.00")
      })

    assert :ok = SourceEditorialWorker.perform(%Oban.Job{args: %{}})

    ai_articles = Content.list_articles() |> Enum.filter(&(&1.author_type == "ai_editor"))
    assert ai_articles == []

    [source] = Ingestion.list_raw_sources(status: "pending")
    assert source.title =~ "transfer rumour"

    [decision] = Intelligence.recent_article_generation_decisions(1)
    assert decision.decision_action == "skipped_budget"
    assert decision.source_count == 1
    assert is_nil(decision.permanent_article_id)

    assert Decimal.compare(Intelligence.monthly_spend(Date.utc_today()), Decimal.new("20.00")) ==
             :eq
  end

  test "updates existing ai article when cluster significance is below threshold" do
    {:ok, _source} =
      Ingestion.create_raw_source(%{
        title: "Leigh cup final injury update",
        url: "https://example.com/low-significance-1",
        body_summary: "Initial injury concern before the cup final.",
        origin_provider: "provider_low",
        external_published_at: ~U[2026-06-29 12:00:00.000000Z]
      })

    assert :ok = SourceEditorialWorker.perform(%Oban.Job{args: %{}})

    [first_article] = Content.list_articles() |> Enum.filter(&(&1.author_type == "ai_editor"))

    {:ok, _source} =
      Ingestion.create_raw_source(%{
        title: "Leigh cup final injury update continues",
        url: "https://example.com/low-significance-2",
        body_summary: "Further fitness notes from the same story line.",
        origin_provider: "provider_low",
        external_published_at: ~U[2026-06-29 13:00:00.000000Z]
      })

    assert :ok = SourceEditorialWorker.perform(%Oban.Job{args: %{}})

    ai_articles = Content.list_articles() |> Enum.filter(&(&1.author_type == "ai_editor"))
    assert length(ai_articles) == 1

    [updated_article] = ai_articles
    assert updated_article.id == first_article.id
    assert updated_article.version == first_article.version + 1

    decisions = Intelligence.recent_article_generation_decisions(5)
    assert Enum.any?(decisions, &(&1.decision_action == "created"))
    assert Enum.any?(decisions, &(&1.decision_action == "updated"))
  end

  test "creates a new ai article when cluster significance meets threshold" do
    {:ok, _source} =
      Ingestion.create_raw_source(%{
        title: "Leigh transfer window headline grows",
        url: "https://example.com/high-significance-base",
        body_summary: "Base transfer headline for this story key.",
        origin_provider: "provider_base",
        external_published_at: ~U[2026-06-29 14:00:00.000000Z]
      })

    assert :ok = SourceEditorialWorker.perform(%Oban.Job{args: %{}})
    [_first_article] = Content.list_articles() |> Enum.filter(&(&1.author_type == "ai_editor"))

    assert {:ok, _} =
             Ingestion.create_raw_source(%{
               title: "Leigh transfer window headline grows with late twist",
               url: "https://example.com/high-significance-1",
               body_summary: "Provider one confirms ongoing transfer movement.",
               origin_provider: "provider_one",
               external_published_at: ~U[2026-06-29 15:00:00.000000Z]
             })

    assert {:ok, _} =
             Ingestion.create_raw_source(%{
               title: "Leigh transfer window headline grows under fresh claims",
               url: "https://example.com/high-significance-2",
               body_summary: "Provider two adds additional transfer context.",
               origin_provider: "provider_two",
               external_published_at: ~U[2026-06-29 15:10:00.000000Z]
             })

    assert {:ok, _} =
             Ingestion.create_raw_source(%{
               title: "Leigh transfer window headline grows amid wider links",
               url: "https://example.com/high-significance-3",
               body_summary: "Provider three contributes related transfer notes.",
               origin_provider: "provider_three",
               external_published_at: ~U[2026-06-29 15:20:00.000000Z]
             })

    assert :ok = SourceEditorialWorker.perform(%Oban.Job{args: %{}})

    ai_articles = Content.list_articles() |> Enum.filter(&(&1.author_type == "ai_editor"))
    assert length(ai_articles) == 2
  end

  test "groups similar headlines into one article and aggregates all source links" do
    assert {:ok, _} =
             Ingestion.create_raw_source(%{
               title: "Super League: Leigh overcome Toulouse as Charnley scores four tries",
               url: "https://example.com/similar-group-1",
               body_summary: "Match report from provider one.",
               origin_provider: "provider_one",
               external_published_at: ~U[2026-06-29 17:00:00.000000Z]
             })

    assert {:ok, _} =
             Ingestion.create_raw_source(%{
               title: "Charnley scores four tries as Leigh beat Toulouse",
               url: "https://example.com/similar-group-2",
               body_summary: "Match report from provider two.",
               origin_provider: "provider_two",
               external_published_at: ~U[2026-06-29 17:05:00.000000Z]
             })

    assert :ok = SourceEditorialWorker.perform(%Oban.Job{args: %{}})

    ai_articles = Content.list_articles() |> Enum.filter(&(&1.author_type == "ai_editor"))
    assert length(ai_articles) == 1

    [article] = ai_articles
    assert article.title =~ "Charnley"

    assert count_article_sources(article.id) == 2

    [decision] = Intelligence.recent_article_generation_decisions(1)
    assert decision.source_count == 2
    assert decision.decision_action == "created"
  end

  test "drains pending backlog across multiple batches in one run" do
    Application.put_env(:leythers_com, :intelligence_generation,
      auto_generation_enabled: true,
      source_batch_size: 2,
      max_batches_per_run: 10,
      significance_threshold: 70,
      prompt_version: "source_editorial_test",
      llm_draft_enabled: false,
      llm_cost_per_1k_tokens_gbp: "0.000000"
    )

    for {suffix, minute} <- [{"one", 10}, {"two", 20}, {"three", 30}, {"four", 40}, {"five", 50}] do
      assert {:ok, _source} =
               Ingestion.create_raw_source(%{
                 title: "Leigh backlog story #{suffix}",
                 url: "https://example.com/backlog-#{suffix}",
                 body_summary: "Backlog summary for #{suffix}",
                 origin_provider: "provider_#{suffix}",
                 external_published_at:
                   ~U[2026-06-29 16:00:00.000000Z] |> DateTime.add(minute * 60, :second)
               })
    end

    assert :ok = SourceEditorialWorker.perform(%Oban.Job{args: %{}})

    pending_count =
      Ingestion.list_raw_sources(status: "pending")
      |> length()

    ai_article_count =
      Content.list_articles()
      |> Enum.filter(&(&1.author_type == "ai_editor"))
      |> length()

    linked_source_count =
      from(article_source in LeythersCom.Content.ArticleSource, select: count(article_source.id))
      |> Repo.one()

    decision_count =
      Intelligence.recent_article_generation_decisions(20)
      |> Enum.count(&(&1.decision_action in ["created", "updated"]))

    assert pending_count == 0
    assert ai_article_count >= 1
    assert linked_source_count == 5
    assert decision_count >= 1
  end

  defp count_article_sources(article_id) do
    import Ecto.Query

    from(article_source in LeythersCom.Content.ArticleSource,
      where: article_source.permanent_article_id == ^article_id,
      select: count(article_source.id)
    )
    |> Repo.one()
  end
end
