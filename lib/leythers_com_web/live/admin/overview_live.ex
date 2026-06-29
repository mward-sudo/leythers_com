defmodule LeythersComWeb.Admin.OverviewLive do
  @moduledoc """
  Authenticated admin overview for provenance and intelligence budget history.
  """

  use LeythersComWeb, :live_view

  alias LeythersCom.Content
  alias LeythersCom.Intelligence

  @impl true
  def mount(_params, _session, socket) do
    started_at = System.monotonic_time()
    today = Date.utc_today()
    monthly_spend = Intelligence.monthly_spend(today)
    monthly_cap = Intelligence.monthly_generation_cap()
    budget_state = Intelligence.generation_budget_state(today)
    recent_ledgers = Intelligence.recent_cost_ledgers(14)
    recent_articles = Content.list_recent_articles_with_sources(10)
    recent_generation_decisions = Intelligence.recent_article_generation_decisions(20)
    failed_jobs = Intelligence.list_failed_jobs(25)

    :telemetry.execute(
      [:leythers_com, :web, :admin_overview, :mount, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{
        result: :ok,
        budget_state: budget_state,
        ledger_count: length(recent_ledgers),
        article_count: length(recent_articles),
        generation_decision_count: length(recent_generation_decisions),
        failed_job_count: length(failed_jobs)
      }
    )

    {:ok,
     socket
     |> assign(:page_title, "Admin Overview")
     |> assign(:today, today)
     |> assign(:monthly_spend, monthly_spend)
     |> assign(:monthly_cap, monthly_cap)
     |> assign(:budget_state, budget_state)
     |> assign(:recent_ledgers, recent_ledgers)
     |> assign(:recent_articles, recent_articles)
     |> assign(:recent_generation_decisions, recent_generation_decisions)
     |> assign(:failed_jobs, failed_jobs)}
  end

  @impl true
  def handle_event("retry-job", %{"id" => id}, socket) do
    with {job_id, ""} <- Integer.parse(id),
         :ok <- Intelligence.retry_failed_job(job_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Queued job ##{job_id} for retry")
       |> assign(:failed_jobs, Intelligence.list_failed_jobs(25))}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Unable to retry that job")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl px-4 py-6 sm:px-6 lg:px-8" id="admin-overview-page">
        <div class="mb-6 flex items-center justify-between">
          <div>
            <h1 class="text-3xl font-semibold tracking-tight">Admin Overview</h1>
            <p class="text-sm text-base-content/70">
              Provenance and budget history for editorial operations.
            </p>
          </div>

          <.link navigate={~p"/admin/articles/new"} class="btn btn-primary btn-soft">
            Open Manual Publish
          </.link>
        </div>

        <section class="grid gap-4 md:grid-cols-3" id="budget-summary">
          <article class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm">
            <h2 class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/60">
              Monthly Spend
            </h2>
            <p class="mt-2 text-2xl font-semibold">{gbp(@monthly_spend)}</p>
          </article>

          <article class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm">
            <h2 class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/60">
              Monthly Cap
            </h2>
            <p class="mt-2 text-2xl font-semibold">{gbp(@monthly_cap)}</p>
          </article>

          <article class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm">
            <h2 class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/60">
              Budget State
            </h2>
            <p class={[
              "mt-2 inline-flex rounded-full px-3 py-1 text-sm font-semibold",
              budget_badge_class(@budget_state)
            ]}>
              {to_string(@budget_state)}
            </p>
          </article>
        </section>

        <div class="mt-6 grid gap-6 lg:grid-cols-2">
          <section
            class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
            id="cost-history"
          >
            <h2 class="text-lg font-semibold">Recent Cost Ledger Entries</h2>

            <div class="mt-4 overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Date</th>
                    <th>Input</th>
                    <th>Output</th>
                    <th>Cost</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for ledger <- @recent_ledgers do %>
                    <tr>
                      <td>{ledger.date}</td>
                      <td>{ledger.input_tokens}</td>
                      <td>{ledger.output_tokens}</td>
                      <td>{gbp(ledger.estimated_cost_gbp)}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </section>

          <section
            class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
            id="provenance-history"
          >
            <h2 class="text-lg font-semibold">Recent Published Articles</h2>

            <div class="mt-4 space-y-3">
              <%= for entry <- @recent_articles do %>
                <article
                  class="rounded-xl border border-base-300 p-4"
                  id={"article-#{entry.article.id}"}
                >
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <p class="text-sm font-semibold">{entry.article.title}</p>
                      <p class="text-xs text-base-content/70">
                        {entry.article.slug} · v{entry.article.version}
                      </p>
                    </div>
                    <span class="badge badge-outline">{length(entry.sources)} source(s)</span>
                  </div>

                  <ul class="mt-3 space-y-2 text-sm">
                    <%= for source <- entry.sources do %>
                      <li class="rounded-lg bg-base-200/70 px-3 py-2" id={"source-#{source.id}"}>
                        <p class="font-medium">{source.title}</p>
                        <p class="text-xs text-base-content/70 break-all">{source.url}</p>
                        <p class="text-xs text-base-content/60">
                          {source.origin_provider} · {source.last_check_status || "unchecked"}
                        </p>
                      </li>
                    <% end %>
                  </ul>
                </article>
              <% end %>
            </div>
          </section>
        </div>

        <section
          class="mt-6 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
          id="generation-decisions"
        >
          <h2 class="text-lg font-semibold">Recent Generation Decisions</h2>
          <p class="mt-1 text-sm text-base-content/70">
            Auditable create/update/skip actions chosen by source editorial automation.
          </p>

          <div class="mt-4 overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Action</th>
                  <th>Sources</th>
                  <th>Score</th>
                  <th>Prompt</th>
                  <th>Cost</th>
                </tr>
              </thead>
              <tbody>
                <%= for decision <- @recent_generation_decisions do %>
                  <tr id={"generation-decision-#{decision.id}"}>
                    <td>{format_decision_time(decision.inserted_at)}</td>
                    <td>{decision.decision_action}</td>
                    <td>{decision.source_count}</td>
                    <td>{decision.significance_score}/{decision.significance_threshold}</td>
                    <td>{decision.prompt_version}</td>
                    <td>{gbp(decision.estimated_cost_gbp)}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </section>

        <section
          class="mt-6 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
          id="dead-letter-jobs"
        >
          <h2 class="text-lg font-semibold">Failed Jobs (Dead Letter)</h2>
          <p class="mt-1 text-sm text-base-content/70">
            Review discarded or retryable jobs and manually queue a retry.
          </p>

          <div class="mt-4 overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>State</th>
                  <th>Queue</th>
                  <th>Worker</th>
                  <th>Attempts</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for job <- @failed_jobs do %>
                  <tr id={"failed-job-#{job.id}"}>
                    <td>#{job.id}</td>
                    <td>{job.state}</td>
                    <td>{job.queue}</td>
                    <td class="max-w-80 truncate">{job.worker}</td>
                    <td>{job.attempt}/{job.max_attempts}</td>
                    <td>
                      <button
                        type="button"
                        class="btn btn-xs btn-outline"
                        phx-click="retry-job"
                        phx-value-id={job.id}
                      >
                        Retry
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp gbp(decimal) do
    "£" <> Decimal.to_string(decimal, :normal)
  end

  defp budget_badge_class(:under_budget), do: "bg-success/15 text-success"
  defp budget_badge_class(:near_budget), do: "bg-warning/20 text-warning"
  defp budget_badge_class(:over_budget), do: "bg-error/20 text-error"

  defp format_decision_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp format_decision_time(_), do: "-"
end
