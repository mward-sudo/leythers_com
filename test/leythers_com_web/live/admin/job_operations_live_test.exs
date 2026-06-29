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

    test "renders process timeline view", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/jobs")

      assert html =~ "Job Operations"
      assert html =~ "Ingestion runs and editorial reviews"
      assert has_element?(view, "#process-timeline")
    end

    test "shows empty state when no processes exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/jobs")

      assert html =~ "No processes yet"
      assert html =~ "Ingestion runs and editorial reviews will appear here"
    end

    test "displays processes with their events", %{conn: conn} do
      process_run_id = Ecto.UUID.generate()

      job =
        create_job(
          "completed",
          "LeythersCom.Intelligence.SourceEditorialWorker",
          "intelligence"
        )

      {:ok, _event} =
        Intelligence.create_job_effect_event(%{
          oban_job_id: job.id,
          worker: "LeythersCom.Intelligence.SourceEditorialWorker",
          queue: "intelligence",
          state: "completed",
          attempt: 1,
          decision_action: "created",
          process_run_id: process_run_id,
          source_ids: [Ecto.UUID.generate()],
          source_input_snapshot: %{
            "sources" => [
              %{
                "headline" => "Test Article",
                "url" => "https://example.com/test",
                "excerpt" => "A test article excerpt."
              }
            ]
          },
          change_summary: "created article",
          change_details: %{outcome: "created"}
        })

      {:ok, view, html} = live(conn, ~p"/admin/jobs")

      assert html =~ "Editorial Review:"
      assert html =~ "sources"
    end

    test "supports process expansion and event display", %{conn: conn} do
      process_run_id = Ecto.UUID.generate()

      job =
        create_job(
          "completed",
          "LeythersCom.Intelligence.SourceEditorialWorker",
          "intelligence"
        )

      {:ok, event} =
        Intelligence.create_job_effect_event(%{
          oban_job_id: job.id,
          worker: "LeythersCom.Intelligence.SourceEditorialWorker",
          queue: "intelligence",
          state: "completed",
          attempt: 1,
          decision_action: "created",
          process_run_id: process_run_id,
          source_ids: [Ecto.UUID.generate()],
          source_input_snapshot: %{
            "sources" => [
              %{
                "headline" => "Expanded Event",
                "url" => "https://example.com/expanded",
                "excerpt" => "Event detail text."
              }
            ]
          },
          change_summary: "created article",
          change_details: %{outcome: "created"}
        })

      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      # Expand process
      view
      |> element("#process-#{process_run_id}")
      |> render_click()

      html = render(view)
      assert html =~ "Events"
      assert html =~ "Editorial Review"

      # Click event to show detail modal
      view
      |> element("#event-btn-#{event.id}")
      |> render_click()

      html = render(view)
      assert html =~ "Event Details"
      assert html =~ "https://example.com/expanded"
    end

    test "supports pagination for processes", %{conn: conn} do
      # Create multiple processes with events
      for i <- 1..21 do
        process_run_id = Ecto.UUID.generate()

        job =
          create_job(
            "completed",
            "LeythersCom.Intelligence.SourceEditorialWorker",
            "intelligence"
          )

        {:ok, _event} =
          Intelligence.create_job_effect_event(%{
            oban_job_id: job.id,
            worker: "LeythersCom.Intelligence.SourceEditorialWorker",
            queue: "intelligence",
            state: "completed",
            attempt: 1,
            decision_action: "created",
            process_run_id: process_run_id,
            source_ids: [Ecto.UUID.generate()],
            source_input_snapshot: %{},
            change_summary: "created article #{i}",
            change_details: %{outcome: "created"}
          })
      end

      {:ok, view, html} = live(conn, ~p"/admin/jobs")

      assert html =~ "Page 1 of 2"

      # Go to next page
      view
      |> element("a", "Next")
      |> render_click()

      html = render(view)
      assert html =~ "Page 2 of 2"
    end

    test "shows ingestion process details", %{conn: conn} do
      process_run_id = Ecto.UUID.generate()

      job =
        create_job("completed", "LeythersCom.Ingestion.FetchRssFeedWorker", "ingestion")

      {:ok, _event} =
        Intelligence.create_job_effect_event(%{
          oban_job_id: job.id,
          worker: "LeythersCom.Ingestion.FetchRssFeedWorker",
          queue: "ingestion",
          state: "completed",
          attempt: 1,
          decision_action: "created",
          process_run_id: process_run_id,
          source_ids: [Ecto.UUID.generate()],
          source_input_snapshot: %{
            "feed" => %{
              "url" => "https://example.com/rss",
              "origin_provider" => "RSS Feed"
            },
            "items" => [
              %{
                "title" => "New Article",
                "url" => "https://example.com/article",
                "status" => "new"
              }
            ]
          },
          change_summary: "fetched feed",
          change_details: %{inserted: 1, seen: 0, errors: 0}
        })

      {:ok, view, html} = live(conn, ~p"/admin/jobs")

      assert html =~ "RSS Feed Ingestion"
      assert html =~ "sources"
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

      _ =
        recent_processed |> RawSource.changeset(%{status: "processed"}) |> Repo.update!()

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

    test "refreshes in real time when job operations update message is received", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      assert render(view) =~ "No processes yet"

      process_run_id = Ecto.UUID.generate()

      job =
        create_job(
          "completed",
          "LeythersCom.Intelligence.SourceEditorialWorker",
          "intelligence"
        )

      {:ok, _event} =
        Intelligence.create_job_effect_event(%{
          oban_job_id: job.id,
          worker: "LeythersCom.Intelligence.SourceEditorialWorker",
          queue: "intelligence",
          state: "completed",
          attempt: 1,
          decision_action: "created",
          process_run_id: process_run_id,
          source_ids: [Ecto.UUID.generate()],
          source_input_snapshot: %{},
          change_summary: "created article",
          change_details: %{outcome: "created"}
        })

      send(view.pid, {:job_operations, :updated})

      html = render(view)
      assert html =~ "Editorial Review:"
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
