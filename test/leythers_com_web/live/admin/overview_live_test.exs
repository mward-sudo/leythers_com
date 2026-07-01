defmodule LeythersComWeb.Admin.OverviewLiveTest do
  use LeythersComWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias LeythersCom.Content
  alias LeythersCom.Ingestion
  alias LeythersCom.Intelligence
  alias Oban.Job

  describe "authentication" do
    test "redirects unauthenticated users to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/overview")
      assert path =~ "/users/log-in"
    end
  end

  describe "index/0" do
    setup :register_and_log_in_user

    setup do
      runtime_env_original = Application.get_env(:leythers_com, :runtime_env)
      llm_provider_original = Application.get_env(:leythers_com, :llm_provider)
      llm_original = Application.get_env(:leythers_com, :llm)
      llm_profiles_original = Application.get_env(:leythers_com, :llm_profiles)

      Application.put_env(:leythers_com, :runtime_env, :dev)

      Application.put_env(:leythers_com, :llm_profiles, %{
        openrouter: [adapter: LeythersCom.Intelligence.LLMClient.OpenRouter],
        ollama: [adapter: LeythersCom.Intelligence.LLMClient.Ollama]
      })

      on_exit(fn ->
        reset_env(:runtime_env, runtime_env_original)
        reset_env(:llm_provider, llm_provider_original)
        reset_env(:llm, llm_original)
        reset_env(:llm_profiles, llm_profiles_original)
      end)

      :ok
    end

    test "renders budget summary and provenance data", %{conn: conn, user: _user} do
      attach_telemetry_handler([:leythers_com, :web, :admin_overview, :mount, :stop])

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

      {:ok, _decision} =
        Intelligence.create_article_generation_decision(%{
          run_id: Ecto.UUID.generate(),
          decision_action: "created",
          source_ids: [source.id],
          source_count: 1,
          significance_score: 85,
          significance_threshold: 70,
          prompt_version: "source_editorial_test",
          decision_summary: "high significance source cluster",
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("0"),
          permanent_article_id: nil
        })

      {:ok, view, html} = live(conn, ~p"/admin/overview")

      assert html =~ "Admin Overview"
      assert has_element?(view, "#budget-summary")
      assert has_element?(view, "#cost-history")
      assert has_element?(view, "#provenance-history")
      assert has_element?(view, "#generation-decisions")
      assert has_element?(view, "#dead-letter-jobs")
      assert has_element?(view, "#provenance-history", "Overview Test Article")
      assert has_element?(view, "#provenance-history", "Overview Test Source")
      assert has_element?(view, "#cost-history", "1.230000")
      assert has_element?(view, "#generation-decisions", "source_editorial_test")

      assert_receive {:telemetry_event, [:leythers_com, :web, :admin_overview, :mount, :stop],
                      measurements, metadata}

      assert measurements.duration > 0
      assert measurements.count == 1
      assert metadata.result == :ok
      assert metadata.budget_state in [:under_budget, :near_budget, :over_budget]
      assert metadata.ledger_count >= 1
      assert metadata.article_count >= 1
      assert metadata.generation_decision_count >= 1
    end

    test "lists failed jobs and allows retry", %{conn: conn, user: _user} do
      job = create_failed_oban_job("discarded")

      {:ok, view, _html} = live(conn, ~p"/admin/overview")

      assert has_element?(view, "#failed-job-#{job.id}")

      view
      |> element("#failed-job-#{job.id} button")
      |> render_click()

      assert render(view) =~ "Queued job ##{job.id} for retry"
    end

    test "renders llm provider controls and switches provider", %{conn: conn, user: _user} do
      Application.put_env(:leythers_com, :llm_provider, :ollama)
      Application.put_env(:leythers_com, :llm, adapter: LeythersCom.Intelligence.LLMClient.Ollama)

      {:ok, view, _html} = live(conn, ~p"/admin/overview")

      assert has_element?(view, "#llm-provider-controls")
      assert has_element?(view, "#llm-provider-buttons button[phx-value-provider='openrouter']")
      assert has_element?(view, "#llm-provider-buttons button[phx-value-provider='ollama']")

      view
      |> element("#llm-provider-buttons button[phx-value-provider='openrouter']")
      |> render_click()

      assert render(view) =~ "LLM provider switched to openrouter"
      assert render(view) =~ "current: OpenRouter"
    end
  end

  defp attach_telemetry_handler(event_name) do
    handler_id = "overview-live-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp create_failed_oban_job(state) when state in ["discarded", "retryable"] do
    job =
      Job.new(
        %{"source" => "overview-test"},
        worker: "LeythersCom.Ingestion.FetchRawSourceWorker",
        queue: :ingestion,
        max_attempts: 5
      )
      |> LeythersCom.Repo.insert!()

    now = DateTime.utc_now()

    from(j in Job, where: j.id == ^job.id)
    |> LeythersCom.Repo.update_all(
      set: [
        state: state,
        attempt: 5,
        attempted_at: now,
        discarded_at: if(state == "discarded", do: now, else: nil)
      ]
    )

    LeythersCom.Repo.get!(Job, job.id)
  end

  defp reset_env(key, nil), do: Application.delete_env(:leythers_com, key)
  defp reset_env(key, value), do: Application.put_env(:leythers_com, key, value)
end
