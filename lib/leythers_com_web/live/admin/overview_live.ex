defmodule LeythersComWeb.Admin.OverviewLive do
  @moduledoc """
  Authenticated admin overview for provenance and intelligence budget history.
  """

  use LeythersComWeb, :live_view

  alias LeythersCom.Content
  alias LeythersCom.Intelligence

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    {:ok,
     socket
     |> assign(:page_title, "Admin Overview")
     |> assign(:today, today)
     |> assign(:monthly_spend, Intelligence.monthly_spend(today))
     |> assign(:monthly_cap, Intelligence.monthly_generation_cap())
     |> assign(:budget_state, Intelligence.generation_budget_state(today))
     |> assign(:recent_ledgers, Intelligence.recent_cost_ledgers(14))
     |> assign(:recent_articles, Content.list_recent_articles_with_sources(10))}
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
end
