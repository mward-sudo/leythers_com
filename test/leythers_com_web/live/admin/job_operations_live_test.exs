defmodule LeythersComWeb.Admin.JobOperationsLiveTest do
  use LeythersComWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

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

    test "renders lifecycle buckets and switches bucket listing", %{conn: conn} do
      executing =
        create_job("executing", "LeythersCom.Intelligence.SourceEditorialWorker", "intelligence")

      scheduled = create_job("scheduled", "LeythersCom.Ingestion.FetchRssFeedWorker", "ingestion")

      _completed =
        create_job("completed", "LeythersCom.Intelligence.SourceEditorialWorker", "intelligence")

      {:ok, view, html} = live(conn, ~p"/admin/jobs")

      assert html =~ "Job Operations"
      assert has_element?(view, "#job-bucket-active")
      assert has_element?(view, "#job-bucket-queued")
      assert has_element?(view, "#job-bucket-terminal")
      assert has_element?(view, "#job-row-#{executing.id}")

      view
      |> element("#job-bucket-queued")
      |> render_click()

      assert has_element?(view, "#job-row-#{scheduled.id}")
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

      {:ok, view, _html} = live(conn, ~p"/admin/jobs?bucket=terminal")

      html =
        view
        |> element("#job-view-#{completed.id}")
        |> render_click()

      assert html =~ "Job ###{completed.id}"
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

      {:ok, view, _html} = live(conn, ~p"/admin/jobs?bucket=terminal")

      assert render(view) =~ "Page 1 of 2"

      view
      |> element("#job-pagination a", "Next")
      |> render_click()

      assert render(view) =~ "Page 2 of 2"
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
