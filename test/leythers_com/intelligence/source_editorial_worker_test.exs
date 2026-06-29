defmodule LeythersCom.Intelligence.SourceEditorialWorkerTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Content
  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.SourceEditorialWorker

  setup do
    original_generation_config = Application.get_env(:leythers_com, :intelligence_generation)

    on_exit(fn ->
      Application.put_env(:leythers_com, :intelligence_generation, original_generation_config)
    end)

    Application.put_env(:leythers_com, :intelligence_generation,
      auto_generation_enabled: true,
      source_batch_size: 20,
      significance_threshold: 70,
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
end
