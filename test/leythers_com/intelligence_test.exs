defmodule LeythersCom.IntelligenceTest do
  use LeythersCom.DataCase, async: true

  import Ecto.Query

  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.CostLedger
  alias Oban.Job

  describe "upsert_cost_ledger/1" do
    test "inserts a new ledger row for a date" do
      attrs = %{
        date: ~D[2026-06-01],
        input_tokens: 1000,
        output_tokens: 200,
        estimated_cost_gbp: Decimal.new("0.001200")
      }

      assert {:ok, %CostLedger{} = ledger} = Intelligence.upsert_cost_ledger(attrs)
      assert ledger.date == ~D[2026-06-01]
      assert ledger.input_tokens == 1000
    end

    test "accumulates tokens when called again for same date" do
      date = ~D[2026-06-02]

      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: date,
          input_tokens: 500,
          output_tokens: 100,
          estimated_cost_gbp: Decimal.new("0.000600")
        })

      {:ok, updated} =
        Intelligence.upsert_cost_ledger(%{
          date: date,
          input_tokens: 300,
          output_tokens: 50,
          estimated_cost_gbp: Decimal.new("0.000350")
        })

      assert updated.input_tokens == 800
      assert updated.output_tokens == 150
    end

    test "returns error changeset for missing date" do
      assert {:error, %Ecto.Changeset{}} = Intelligence.upsert_cost_ledger(%{})
    end
  end

  describe "monthly_spend/1" do
    test "returns sum of estimated_cost_gbp for a given year-month" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-01],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("3.000000")
        })

      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-02],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("2.500000")
        })

      total = Intelligence.monthly_spend(~D[2026-06-01])
      assert Decimal.equal?(total, Decimal.new("5.500000"))
    end

    test "returns zero for a month with no entries" do
      total = Intelligence.monthly_spend(~D[2025-01-01])
      assert Decimal.equal?(total, Decimal.new("0"))
    end
  end

  describe "monthly_budget_state/2" do
    test "returns under_budget below the warning threshold" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-01],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("20.00")
        })

      assert Intelligence.monthly_budget_state(~D[2026-06-01], Decimal.new("100.00")) ==
               :under_budget
    end

    test "returns near_budget at or above eighty percent of the cap" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-02],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("80.00")
        })

      assert Intelligence.monthly_budget_state(~D[2026-06-01], Decimal.new("100.00")) ==
               :near_budget
    end

    test "returns over_budget when the monthly spend meets the cap" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-03],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("100.00")
        })

      assert Intelligence.monthly_budget_state(~D[2026-06-01], Decimal.new("100.00")) ==
               :over_budget
    end
  end

  describe "monthly_generation_cap/0" do
    test "reads the configured default cap" do
      cap = Intelligence.monthly_generation_cap()
      assert Decimal.equal?(cap, Decimal.new("10.00"))
    end
  end

  describe "effective_monthly_cap/2" do
    test "uses the configured cap when no override is present" do
      cap = Intelligence.effective_monthly_cap(~D[2026-06-01], nil)
      assert Decimal.equal?(cap, Decimal.new("10.00"))
    end

    test "uses a valid month-end override to raise the cap" do
      override = %{monthly_cap_gbp: Decimal.new("15.00"), expires_on: ~D[2026-06-30]}
      cap = Intelligence.effective_monthly_cap(~D[2026-06-15], override)

      assert Decimal.equal?(cap, Decimal.new("15.00"))
    end

    test "ignores overrides that do not expire at month end" do
      override = %{monthly_cap_gbp: Decimal.new("15.00"), expires_on: ~D[2026-06-29]}
      cap = Intelligence.effective_monthly_cap(~D[2026-06-15], override)

      assert Decimal.equal?(cap, Decimal.new("10.00"))
    end
  end

  describe "generation_budget_state/2" do
    test "applies the effective cap before classifying spend" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-10],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("12.00")
        })

      override = %{monthly_cap_gbp: Decimal.new("15.00"), expires_on: ~D[2026-06-30]}

      assert Intelligence.generation_budget_state(~D[2026-06-01], override) == :near_budget
    end
  end

  describe "generation_allowed?/2" do
    test "returns true while the budget is still available" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-11],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("4.00")
        })

      assert Intelligence.generation_allowed?(~D[2026-06-01])
    end

    test "returns false when the budget is exceeded" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-12],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("10.00")
        })

      refute Intelligence.generation_allowed?(~D[2026-06-01])
    end
  end

  describe "ensure_generation_allowed!/2" do
    test "returns ok when generation is allowed" do
      attach_telemetry_handler([:leythers_com, :intelligence, :generation_budget, :check, :stop])

      assert :ok = Intelligence.ensure_generation_allowed!(~D[2026-06-01])

      {measurements, metadata} = wait_for_budget_check_event(:under_budget, 5)

      assert measurements.duration > 0
      assert measurements.count == 1
      assert metadata.result == :ok
      assert metadata.budget_state == :under_budget
    end

    test "returns an over_budget error when generation is blocked" do
      attach_telemetry_handler([:leythers_com, :intelligence, :generation_budget, :check, :stop])

      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-13],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("10.00")
        })

      assert {:error, :over_budget} = Intelligence.ensure_generation_allowed!(~D[2026-06-01])

      {measurements, metadata} = wait_for_budget_check_event(:over_budget, 5)

      assert measurements.duration > 0
      assert measurements.count == 1
      assert metadata.result == :error
      assert metadata.budget_state == :over_budget
    end
  end

  describe "recent_cost_ledgers/1" do
    test "returns most recent ledgers first and respects the limit" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-08],
          input_tokens: 10,
          output_tokens: 5,
          estimated_cost_gbp: Decimal.new("1.00")
        })

      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-09],
          input_tokens: 20,
          output_tokens: 10,
          estimated_cost_gbp: Decimal.new("2.00")
        })

      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-10],
          input_tokens: 30,
          output_tokens: 15,
          estimated_cost_gbp: Decimal.new("3.00")
        })

      ledgers = Intelligence.recent_cost_ledgers(2)

      assert length(ledgers) == 2
      assert Enum.map(ledgers, & &1.date) == [~D[2026-06-10], ~D[2026-06-09]]
    end

    test "returns empty list for non-positive limits" do
      assert Intelligence.recent_cost_ledgers(0) == []
    end
  end

  describe "article generation decisions" do
    test "creates and lists recent decisions" do
      run_id = Ecto.UUID.generate()

      assert {:ok, created} =
               Intelligence.create_article_generation_decision(%{
                 run_id: run_id,
                 decision_action: "created",
                 source_ids: [Ecto.UUID.generate()],
                 source_count: 1,
                 significance_score: 80,
                 significance_threshold: 70,
                 prompt_version: "source_editorial_test",
                 decision_summary: "created due to high significance",
                 input_tokens: 0,
                 output_tokens: 0,
                 estimated_cost_gbp: Decimal.new("0")
               })

      assert {:ok, skipped} =
               Intelligence.create_article_generation_decision(%{
                 run_id: run_id,
                 decision_action: "skipped_budget",
                 source_ids: [Ecto.UUID.generate()],
                 source_count: 1,
                 significance_score: 80,
                 significance_threshold: 70,
                 prompt_version: "source_editorial_test",
                 decision_summary: "skipped due to budget",
                 input_tokens: 0,
                 output_tokens: 0,
                 estimated_cost_gbp: Decimal.new("0")
               })

      decisions = Intelligence.recent_article_generation_decisions(2)

      assert length(decisions) == 2
      assert Enum.map(decisions, & &1.id) == [skipped.id, created.id]
    end

    test "returns empty list for non-positive limits" do
      assert Intelligence.recent_article_generation_decisions(0) == []
    end
  end

  describe "job effect events" do
    test "creates and queries events by job id" do
      assert {:ok, first} =
               Intelligence.create_job_effect_event(%{
                 oban_job_id: 101,
                 worker: "LeythersCom.Intelligence.SourceEditorialWorker",
                 queue: "intelligence",
                 state: "completed",
                 attempt: 1,
                 decision_action: "created",
                 source_ids: [Ecto.UUID.generate()],
                 source_input_snapshot: %{"items" => [%{"title" => "Leigh headline"}]},
                 change_summary: "created article",
                 change_details: %{source_count: 1}
               })

      assert {:ok, second} =
               Intelligence.create_job_effect_event(%{
                 oban_job_id: 101,
                 worker: "LeythersCom.Intelligence.SourceEditorialWorker",
                 queue: "intelligence",
                 state: "completed",
                 attempt: 1,
                 decision_action: "updated",
                 source_ids: [Ecto.UUID.generate()],
                 source_input_snapshot: %{"items" => [%{"title" => "Leigh follow up"}]},
                 change_summary: "updated article",
                 change_details: %{source_count: 1}
               })

      assert {:ok, _third} =
               Intelligence.create_job_effect_event(%{
                 oban_job_id: 202,
                 worker: "LeythersCom.Ingestion.FetchRssFeedWorker",
                 queue: "ingestion",
                 state: "retryable",
                 attempt: 2,
                 decision_action: "skipped_publish_error",
                 source_ids: [],
                 source_input_snapshot: %{"feed" => %{"url" => "https://example.com/rss.xml"}},
                 change_summary: "processed 0; inserted 0; errors 1",
                 change_details: %{processed: 0, inserted: 0, errors: 1},
                 error_summary: "timeout"
               })

      by_job = Intelligence.job_effect_events_for_job(101)
      assert Enum.map(by_job, & &1.id) == [first.id, second.id]

      recent = Intelligence.recent_job_effect_events(2)
      assert length(recent) == 2
      assert Enum.map(recent, & &1.oban_job_id) == [202, 101]
    end

    test "returns empty lists for invalid limits and ids" do
      assert Intelligence.recent_job_effect_events(0) == []
      assert Intelligence.job_effect_events_for_job(0) == []
    end
  end

  describe "job operations queries" do
    test "groups jobs into active, queued, and terminal bucket counts" do
      _ =
        create_oban_job(
          "executing",
          "LeythersCom.Intelligence.SourceEditorialWorker",
          "intelligence"
        )

      _ = create_oban_job("available", "LeythersCom.Ingestion.FetchRssFeedWorker", "ingestion")
      _ = create_oban_job("retryable", "LeythersCom.Ingestion.FetchRssFeedWorker", "ingestion")

      assert {:ok, _event_1} =
               Intelligence.create_job_effect_event(%{
                 oban_job_id: 501,
                 worker: "LeythersCom.Intelligence.SourceEditorialWorker",
                 queue: "intelligence",
                 state: "completed",
                 attempt: 1,
                 decision_action: "created",
                 source_ids: [Ecto.UUID.generate()],
                 source_input_snapshot: %{"sources" => [%{"url" => "https://example.com/a"}]},
                 change_summary: "created article",
                 change_details: %{outcome: "created"}
               })

      assert {:ok, _event_2} =
               Intelligence.create_job_effect_event(%{
                 oban_job_id: 502,
                 worker: "LeythersCom.Intelligence.SourceEditorialWorker",
                 queue: "intelligence",
                 state: "cancelled",
                 attempt: 1,
                 decision_action: "skipped_budget",
                 source_ids: [Ecto.UUID.generate()],
                 source_input_snapshot: %{"sources" => [%{"url" => "https://example.com/b"}]},
                 change_summary: "budget blocked",
                 change_details: %{outcome: "skipped"}
               })

      counts = Intelligence.job_operations_bucket_counts()

      assert counts.active == 1
      assert counts.queued == 2
      assert counts.terminal == 2
    end

    test "filters and paginates jobs by bucket" do
      for idx <- 1..3 do
        assert {:ok, _event} =
                 Intelligence.create_job_effect_event(%{
                   oban_job_id: 700 + idx,
                   worker: "LeythersCom.Intelligence.SourceEditorialWorker",
                   queue: "intelligence",
                   state: "completed",
                   attempt: 1,
                   decision_action: "created",
                   source_ids: [Ecto.UUID.generate()],
                   source_input_snapshot: %{
                     "sources" => [%{"url" => "https://example.com/#{idx}"}]
                   },
                   change_summary: "created article #{idx}",
                   change_details: %{outcome: "created", index: idx}
                 })
      end

      queued =
        create_oban_job("scheduled", "LeythersCom.Ingestion.FetchRssFeedWorker", "ingestion")

      first_page =
        Intelligence.list_job_operations_jobs("terminal", %{page: 1, per_page: 2})

      second_page =
        Intelligence.list_job_operations_jobs("terminal", %{page: 2, per_page: 2})

      filtered =
        Intelligence.list_job_operations_jobs("queued", %{
          queue: "ingestion",
          worker: "FetchRssFeedWorker",
          state: "scheduled",
          page: 1,
          per_page: 20
        })

      assert first_page.total_count == 3
      assert first_page.total_pages == 2
      assert length(first_page.entries) == 2

      assert second_page.total_count == 3
      assert second_page.page == 2
      assert length(second_page.entries) == 1

      assert filtered.total_count == 1
      assert Enum.map(filtered.entries, & &1.id) == [queued.id]
    end

    test "returns persisted diagnostics for a selected job" do
      job =
        create_oban_job(
          "completed",
          "LeythersCom.Intelligence.SourceEditorialWorker",
          "intelligence"
        )

      assert {:ok, _event} =
               Intelligence.create_job_effect_event(%{
                 oban_job_id: job.id,
                 worker: "LeythersCom.Intelligence.SourceEditorialWorker",
                 queue: "intelligence",
                 state: "completed",
                 attempt: 1,
                 decision_action: "created",
                 source_ids: [Ecto.UUID.generate()],
                 source_input_snapshot: %{"sources" => [%{"url" => "https://example.com/a"}]},
                 change_summary: "created article",
                 change_details: %{outcome: "created"}
               })

      detail = Intelligence.job_operations_detail(job.id)

      assert detail.job.id == job.id
      assert length(detail.events) == 1
      assert hd(detail.events).decision_action == "created"
      assert Intelligence.job_operations_detail(0) == nil
    end

    test "returns synthetic detail when oban job row is gone but diagnostics remain" do
      job =
        create_oban_job(
          "completed",
          "LeythersCom.Intelligence.SourceEditorialWorker",
          "intelligence"
        )

      assert {:ok, _event} =
               Intelligence.create_job_effect_event(%{
                 oban_job_id: job.id,
                 worker: "LeythersCom.Intelligence.SourceEditorialWorker",
                 queue: "intelligence",
                 state: "completed",
                 attempt: 1,
                 decision_action: "created",
                 source_ids: [Ecto.UUID.generate()],
                 source_input_snapshot: %{"sources" => [%{"url" => "https://example.com/a"}]},
                 change_summary: "created article",
                 change_details: %{outcome: "created"}
               })

      assert {:ok, _deleted_job} = Repo.delete(job)

      detail = Intelligence.job_operations_detail(job.id)

      assert detail.job.id == job.id
      assert detail.job.source == :history
      assert length(detail.events) == 1
      assert hd(detail.events).decision_action == "created"
    end
  end

  describe "list_failed_jobs/1" do
    test "returns retryable and discarded jobs" do
      discarded_job = create_failed_oban_job("discarded")
      retryable_job = create_failed_oban_job("retryable")

      jobs = Intelligence.list_failed_jobs(25)
      returned_ids = Enum.map(jobs, & &1.id)

      assert discarded_job.id in returned_ids
      assert retryable_job.id in returned_ids
    end

    test "returns empty list for non-positive limits" do
      assert Intelligence.list_failed_jobs(0) == []
    end
  end

  describe "retry_failed_job/1" do
    test "retries a failed job" do
      job = create_failed_oban_job("discarded")

      assert :ok = Intelligence.retry_failed_job(job.id)
    end

    test "returns error for invalid job id" do
      assert {:error, :invalid_job_id} = Intelligence.retry_failed_job("abc")
    end

    test "emits telemetry for retry attempts" do
      job = create_failed_oban_job("discarded")
      attach_telemetry_handler([:leythers_com, :intelligence, :dead_letter, :retry, :stop])

      assert :ok = Intelligence.retry_failed_job(job.id)

      assert_receive {:telemetry_event,
                      [:leythers_com, :intelligence, :dead_letter, :retry, :stop], measurements,
                      metadata}

      assert measurements.duration > 0
      assert measurements.count == 1
      assert metadata.result == :ok
      assert metadata.job_id == job.id
    end
  end

  describe "recover_source_editorial_work/0" do
    test "cancels stale source editorial jobs and enqueues backlog drain" do
      stale_job =
        create_oban_job(
          "executing",
          "LeythersCom.Intelligence.SourceEditorialWorker",
          "intelligence"
        )

      unrelated_job =
        create_oban_job(
          "available",
          "LeythersCom.Ingestion.FetchRssFeedWorker",
          "ingestion"
        )

      assert {:ok, %{cancelled_jobs: 1, enqueue_status: :ok}} =
               Intelligence.recover_source_editorial_work()

      assert Repo.get!(Job, stale_job.id).state == "cancelled"
      assert Repo.get!(Job, unrelated_job.id).state == "available"
    end
  end

  defp attach_telemetry_handler(event_name) do
    handler_id = "intelligence-test-#{System.unique_integer([:positive, :monotonic])}"

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
        %{"source" => "test"},
        worker: "LeythersCom.Ingestion.FetchRawSourceWorker",
        queue: :ingestion,
        max_attempts: 5
      )
      |> LeythersCom.Repo.insert!()

    now = DateTime.utc_now()

    updates = [
      state: state,
      attempt: 5,
      attempted_at: now,
      discarded_at: if(state == "discarded", do: now, else: nil)
    ]

    from(j in Job, where: j.id == ^job.id)
    |> LeythersCom.Repo.update_all(set: updates)

    LeythersCom.Repo.get!(Job, job.id)
  end

  defp create_oban_job(state, worker, queue) do
    job =
      Job.new(%{"source" => "test"},
        worker: worker,
        queue: String.to_atom(queue),
        max_attempts: 5
      )
      |> LeythersCom.Repo.insert!()

    now = DateTime.utc_now()

    from(j in Job, where: j.id == ^job.id)
    |> LeythersCom.Repo.update_all(
      set: [
        state: state,
        attempt: if(state == "executing", do: 1, else: 2),
        attempted_at: now,
        completed_at: if(state == "completed", do: now, else: nil),
        cancelled_at: if(state == "cancelled", do: now, else: nil),
        discarded_at: if(state == "discarded", do: now, else: nil)
      ]
    )

    LeythersCom.Repo.get!(Job, job.id)
  end

  defp wait_for_budget_check_event(_budget_state, 0) do
    flunk("missing expected generation budget telemetry")
  end

  defp wait_for_budget_check_event(budget_state, attempts_left) do
    assert_receive {:telemetry_event,
                    [:leythers_com, :intelligence, :generation_budget, :check, :stop],
                    measurements, metadata}

    if metadata.budget_state == budget_state do
      {measurements, metadata}
    else
      wait_for_budget_check_event(budget_state, attempts_left - 1)
    end
  end
end
