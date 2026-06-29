defmodule LeythersComWeb.Admin.JobOperationsLiveTest do
  use LeythersComWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Intelligence
  alias LeythersCom.Repo
  alias Oban.Job

  describe "authentication" do
    test "redirects unauthenticated users to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/jobs")
      assert path =~ "/users/log-in"
    end
  end

  describe "index" do
    setup :register_and_log_in_user

    test "renders all three job columns simultaneously", %{conn: conn} do
      executing =
        create_job("executing", "LeythersCom.Intelligence.SourceEditorialWorker", "intelligence")

      scheduled = create_job("scheduled", "LeythersCom.Ingestion.FetchRssFeedWorker", "ingestion")

      {:ok, view, html} = live(conn, ~p"/admin/jobs")

      assert html =~ "Job Operations"
      assert has_element?(view, "#col-active")
      assert has_element?(view, "#col-queued")
      assert has_element?(view, "#col-terminal")
      assert has_element?(view, "#job-card-#{executing.id}")
      assert has_element?(view, "#job-card-#{scheduled.id}")
    end

    test "shows persisted diagnostics in the drill-down pane", %{conn: conn} do
      completed =
        create_job("completed", "LeythersCom.Intelligence.SourceEditorialWorker", "intelligence")

      assert {:ok, _event} =
               Intelligence.create_job_effect_event(%{
                 oban_job_id: completed.id,
                 worker: "LeythersCom.Intelligence.SourceEditorialWorker",
                 queue: "intelligence",
                 state: "completed",
                 attempt: 1,
                 decision_action: "created",
                 source_ids: [Ecto.UUID.generate()],
                 source_input_snapshot: %{
                   "sources" => [
                     %{
                       "headline" => "Leigh derby update",
                       "url" => "https://example.com/derby",
                       "excerpt" => "Leigh push on with momentum."
                     }
                   ]
                 },
                 change_summary: "created article",
                 change_details: %{outcome: "created", target_article_identifier: "test-123"}
               })

      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      html =
        view
        |> element("#job-card-#{completed.id}")
        |> render_click()

      assert html =~ "Job #"
      assert html =~ "https://example.com/derby"
      assert html =~ "target_article_identifier"
    end

    test "supports pagination for terminal jobs", %{conn: conn} do
      for _ <- 1..21 do
        _ =
          create_job(
            "completed",
            "LeythersCom.Intelligence.SourceEditorialWorker",
            "intelligence"
          )
      end

      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      assert render(view) =~ "1 / 2"

      view
      |> element("#terminal-pagination a", "Next →")
      |> render_click()

      assert render(view) =~ "2 / 2"
    end

    test "refreshes in real time when job operations update message is received", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      assert has_element?(view, "#col-active")

      executing =
        create_job("executing", "LeythersCom.Intelligence.SourceEditorialWorker", "intelligence")

      send(view.pid, {:job_operations, :updated})

      assert has_element?(view, "#job-card-#{executing.id}")
    end

    test "regenerates all processed sources from admin controls", %{conn: conn} do
      {:ok, processed_a} =
        Ingestion.create_raw_source(%{
          title: "All Regen A",
          url: "https://example.com/all-regen-a",
          origin_provider: "job_ops_regen",
          external_published_at: ~U[2026-06-28 10:00:00.000000Z]
        })

      _ = processed_a |> RawSource.changeset(%{status: "processed"}) |> Repo.update!()

      {:ok, processed_b} =
        Ingestion.create_raw_source(%{
          title: "All Regen B",
          url: "https://example.com/all-regen-b",
          origin_provider: "job_ops_regen",
          external_published_at: ~U[2026-06-01 10:00:00.000000Z]
        })

      _ = processed_b |> RawSource.changeset(%{status: "processed"}) |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      view
      |> element("#regenerate-all-button")
      |> render_click()

      assert render(view) =~ "Queued full regeneration"
      assert Repo.get!(RawSource, processed_a.id).status == "pending"
      assert Repo.get!(RawSource, processed_b.id).status == "pending"
    end

    test "regenerates only recent processed sources from admin controls", %{conn: conn} do
      {:ok, recent_processed} =
        Ingestion.create_raw_source(%{
          title: "Recent Regen",
          url: "https://example.com/recent-regen",
          origin_provider: "job_ops_regen",
          external_published_at: DateTime.utc_now()
        })

      _ = recent_processed |> RawSource.changeset(%{status: "processed"}) |> Repo.update!()

      {:ok, old_processed} =
        Ingestion.create_raw_source(%{
          title: "Old Regen",
          url: "https://example.com/old-regen",
          origin_provider: "job_ops_regen",
          external_published_at: ~U[2026-01-01 10:00:00.000000Z]
        })

      _ = old_processed |> RawSource.changeset(%{status: "processed"}) |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      view
      |> element("#regenerate-recent-button")
      |> render_click()

      assert render(view) =~ "Queued recent regeneration (last 2 weeks)"
      assert Repo.get!(RawSource, recent_processed.id).status == "pending"
      assert Repo.get!(RawSource, old_processed.id).status == "processed"
    end
  end

  defp create_job(state, worker, queue) do
    job =
      Job.new(%{"source" => "job-ops-test"},
        worker: worker,
        queue: String.to_atom(queue),
        max_attempts: 5
      )
      |> Repo.insert!()

    now = DateTime.utc_now()

    from(j in Job, where: j.id == ^job.id)
    |> Repo.update_all(
      set: [
        state: state,
        attempt: if(state == "executing", do: 1, else: 2),
        attempted_at: now,
        completed_at: if(state == "completed", do: now, else: nil),
        cancelled_at: if(state == "cancelled", do: now, else: nil),
        discarded_at: if(state == "discarded", do: now, else: nil)
      ]
    )

    Repo.get!(Job, job.id)
  end
end
