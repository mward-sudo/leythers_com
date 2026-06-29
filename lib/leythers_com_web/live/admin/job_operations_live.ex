defmodule LeythersComWeb.Admin.JobOperationsLive do
  @moduledoc """
  Authenticated admin panel for queue lifecycle and job diagnostics visibility.
  """

  use LeythersComWeb, :live_view

  alias LeythersCom.Ingestion
  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.JobOperationsUpdates

  @default_bucket "active"
  @default_page 1
  @per_page 20
  @time_window_options [
    {"Any time", ""},
    {"Last 24h", "24"},
    {"Last 72h", "72"},
    {"Last 7d", "168"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    filter_options = Intelligence.job_operations_filter_options()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(LeythersCom.PubSub, JobOperationsUpdates.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Job Operations")
     |> assign(:filter_options, filter_options)
     |> assign(:time_window_options, @time_window_options)
     |> assign(:query_params, %{})
     |> assign(:filters, default_filters())
     |> assign(:bucket, @default_bucket)
     |> assign(:jobs_page, empty_page())
     |> assign(:bucket_counts, %{active: 0, queued: 0, terminal: 0})
     |> assign(:selected_job_detail, nil)
     |> assign(:filters_form, to_form(default_filters(), as: :filters))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_page(socket, params)}
  end

  @impl true
  def handle_info({:job_operations, :updated}, socket) do
    {:noreply, load_page(socket, socket.assigns.query_params)}
  end

  defp load_page(socket, params) do
    bucket = normalize_bucket(params["bucket"])
    page = parse_positive_int(params["page"], @default_page)
    filters = normalize_filters(params)

    jobs_page =
      Intelligence.list_job_operations_jobs(bucket, %{
        queue: filters["queue"],
        worker: filters["worker"],
        state: filters["state"],
        time_window_hours: filters["time_window_hours"],
        page: page,
        per_page: @per_page
      })

    bucket_counts =
      Intelligence.job_operations_bucket_counts(%{
        queue: filters["queue"],
        worker: filters["worker"],
        state: filters["state"],
        time_window_hours: filters["time_window_hours"]
      })

    selected_job_detail =
      params
      |> Map.get("job_id")
      |> parse_positive_int(nil)
      |> case do
        nil -> nil
        job_id -> Intelligence.job_operations_detail(job_id)
      end

    query_params =
      params
      |> Map.take(["bucket", "page", "queue", "worker", "state", "time_window_hours", "job_id"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    socket
    |> assign(:query_params, query_params)
    |> assign(:bucket, bucket)
    |> assign(:filters, filters)
    |> assign(:jobs_page, jobs_page)
    |> assign(:bucket_counts, bucket_counts)
    |> assign(:selected_job_detail, selected_job_detail)
    |> assign(:filters_form, to_form(filters, as: :filters))
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => filters}, socket) do
    normalized = normalize_filters(filters)

    params =
      normalized
      |> Map.put("bucket", socket.assigns.bucket)
      |> Map.put("page", "1")

    {:noreply, push_patch(socket, to: ~p"/admin/jobs?#{params}")}
  end

  @impl true
  def handle_event("regenerate-all", _params, socket) do
    {:ok, %{requeued_sources: requeued_sources}} = Ingestion.enqueue_article_regeneration(:all)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Queued full regeneration and re-queued #{requeued_sources} processed source(s)."
     )
     |> refresh_page()}
  end

  @impl true
  def handle_event("regenerate-recent", _params, socket) do
    {:ok, %{requeued_sources: requeued_sources}} =
      Ingestion.enqueue_article_regeneration(:recent)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Queued recent regeneration (last 2 weeks) and re-queued #{requeued_sources} processed source(s)."
     )
     |> refresh_page()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-8" id="job-operations-page">
        <div class="mb-6 flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-3xl font-semibold tracking-tight">Job Operations</h1>
            <p class="text-sm text-base-content/70">
              Live queue visibility and historical diagnostics for ingestion/editorial jobs.
            </p>
          </div>

          <div class="flex items-center gap-2">
            <.link navigate={~p"/admin/overview"} class="btn btn-outline btn-sm">
              Admin Overview
            </.link>
            <.link navigate={~p"/admin/articles/new"} class="btn btn-primary btn-soft btn-sm">
              Manual Publish
            </.link>
          </div>
        </div>

        <section class="grid gap-4 md:grid-cols-3" id="job-lifecycle-buckets">
          <.bucket_card
            id="job-bucket-active"
            label="Active"
            states="executing"
            count={@bucket_counts.active}
            current_bucket={@bucket}
            target_bucket="active"
            params={@query_params}
          />
          <.bucket_card
            id="job-bucket-queued"
            label="Queued"
            states="available, scheduled, retryable"
            count={@bucket_counts.queued}
            current_bucket={@bucket}
            target_bucket="queued"
            params={@query_params}
          />
          <.bucket_card
            id="job-bucket-terminal"
            label="Completed / Terminal"
            states="completed, discarded, cancelled"
            count={@bucket_counts.terminal}
            current_bucket={@bucket}
            target_bucket="terminal"
            params={@query_params}
          />
        </section>

        <section
          class="mt-6 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
          id="regeneration-controls"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold">Regenerate Articles</h2>
              <p class="text-sm text-base-content/70">
                Re-queue previously processed sources and run editorial generation now.
              </p>
            </div>

            <div class="flex items-center gap-2">
              <button
                id="regenerate-recent-button"
                type="button"
                class="btn btn-outline btn-sm"
                phx-click="regenerate-recent"
              >
                Regenerate Recent (2 Weeks)
              </button>

              <button
                id="regenerate-all-button"
                type="button"
                class="btn btn-primary btn-sm"
                phx-click="regenerate-all"
              >
                Regenerate All
              </button>
            </div>
          </div>
        </section>

        <section
          class="mt-6 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
          id="job-filters"
        >
          <h2 class="text-lg font-semibold">Filters</h2>

          <.form
            for={@filters_form}
            id="job-filters-form"
            phx-change="apply_filters"
            class="mt-4 grid gap-4 lg:grid-cols-4"
          >
            <.input
              field={@filters_form[:queue]}
              type="select"
              label="Queue"
              options={[{"All", ""} | Enum.map(@filter_options.queues, &{&1, &1})]}
            />
            <.input
              field={@filters_form[:state]}
              type="select"
              label="State"
              options={[{"All", ""} | Enum.map(@filter_options.states, &{&1, &1})]}
            />
            <.input
              field={@filters_form[:time_window_hours]}
              type="select"
              label="Time Window"
              options={@time_window_options}
            />
            <.input
              field={@filters_form[:worker]}
              type="text"
              label="Worker contains"
              placeholder="SourceEditorialWorker"
            />
          </.form>
        </section>

        <section
          class="mt-6 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
          id="job-list"
        >
          <div class="mb-4 flex items-center justify-between gap-3">
            <h2 class="text-lg font-semibold">{bucket_title(@bucket)} Jobs</h2>
            <p class="text-sm text-base-content/70">{@jobs_page.total_count} matching job(s)</p>
          </div>

          <%= if @jobs_page.entries == [] do %>
            <p class="rounded-xl border border-dashed border-base-300 bg-base-200/60 px-4 py-6 text-sm text-base-content/70">
              No jobs match the selected filters.
            </p>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>State</th>
                    <th>Queue</th>
                    <th>Worker</th>
                    <th>Attempt</th>
                    <th>Inserted</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for job <- @jobs_page.entries do %>
                    <tr id={"job-row-#{job.id}"}>
                      <td>#{job.id}</td>
                      <td>{job.state}</td>
                      <td>{job.queue}</td>
                      <td class="max-w-sm truncate">{job.worker}</td>
                      <td>{job.attempt}/{job.max_attempts}</td>
                      <td>{format_datetime(job.inserted_at)}</td>
                      <td>
                        <.link
                          patch={jobs_path(@query_params, %{job_id: to_string(job.id)})}
                          id={"job-view-#{job.id}"}
                          class="btn btn-xs btn-outline"
                        >
                          Details
                        </.link>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>

          <div class="mt-4 flex items-center justify-between" id="job-pagination">
            <.link
              patch={
                jobs_path(@query_params, %{page: to_string(max(@jobs_page.page - 1, 1)), job_id: nil})
              }
              class={[
                "btn btn-sm btn-outline",
                @jobs_page.page <= 1 && "btn-disabled pointer-events-none opacity-50"
              ]}
            >
              Previous
            </.link>

            <p class="text-sm text-base-content/70">
              Page {@jobs_page.page} of {@jobs_page.total_pages}
            </p>

            <.link
              patch={
                jobs_path(@query_params, %{
                  page: to_string(min(@jobs_page.page + 1, @jobs_page.total_pages)),
                  job_id: nil
                })
              }
              class={[
                "btn btn-sm btn-outline",
                @jobs_page.page >= @jobs_page.total_pages &&
                  "btn-disabled pointer-events-none opacity-50"
              ]}
            >
              Next
            </.link>
          </div>
        </section>

        <section
          class="mt-6 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
          id="job-detail"
        >
          <h2 class="text-lg font-semibold">Diagnostics Drill-down</h2>

          <%= if is_nil(@selected_job_detail) do %>
            <p class="mt-3 text-sm text-base-content/70">
              Select a job row to inspect what happened during that run.
            </p>
          <% else %>
            <p class="mt-3 text-sm text-base-content/70" id="selected-job-meta">
              Job ##{@selected_job_detail.job.id} · {@selected_job_detail.job.worker} · {@selected_job_detail.job.state}
            </p>

            <%= if @selected_job_detail.events == [] do %>
              <p class="mt-4 rounded-xl border border-dashed border-warning/40 bg-warning/10 px-4 py-3 text-sm">
                No persisted diagnostics events found for this job.
              </p>
            <% else %>
              <div class="mt-4 space-y-6">
                <%= for event <- @selected_job_detail.events do %>
                  <%= if ingestion_event?(event) do %>
                    <.ingestion_event_detail event={event} />
                  <% else %>
                    <.editorial_event_detail event={event} />
                  <% end %>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :states, :string, required: true
  attr :count, :integer, required: true
  attr :current_bucket, :string, required: true
  attr :target_bucket, :string, required: true
  attr :params, :map, required: true

  defp bucket_card(assigns) do
    ~H"""
    <.link
      patch={jobs_path(@params, %{bucket: @target_bucket, page: "1", job_id: nil})}
      id={@id}
      class={[
        "block rounded-2xl border p-4 shadow-sm transition",
        @current_bucket == @target_bucket && "border-primary bg-primary/5",
        @current_bucket != @target_bucket && "border-base-300 bg-base-100 hover:border-primary/50"
      ]}
    >
      <h2 class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/60">{@label}</h2>
      <p class="mt-2 text-2xl font-semibold">{@count}</p>
      <p class="mt-1 text-xs text-base-content/60">{@states}</p>
    </.link>
    """
  end

  defp jobs_path(query_params, overrides) do
    params =
      query_params
      |> Map.merge(stringify_keys(overrides))
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/admin/jobs?#{params}"
  end

  defp stringify_keys(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp bucket_title("active"), do: "Active"
  defp bucket_title("queued"), do: "Queued"
  defp bucket_title("terminal"), do: "Completed / Terminal"

  defp normalize_bucket(bucket) when bucket in ["active", "queued", "terminal"], do: bucket
  defp normalize_bucket(_bucket), do: @default_bucket

  defp normalize_filters(params) do
    %{
      "queue" => normalize_filter_value(Map.get(params, "queue")),
      "worker" => normalize_filter_value(Map.get(params, "worker")),
      "state" => normalize_filter_value(Map.get(params, "state")),
      "time_window_hours" => normalize_time_window(Map.get(params, "time_window_hours"))
    }
  end

  defp default_filters do
    %{"queue" => "", "worker" => "", "state" => "", "time_window_hours" => ""}
  end

  defp normalize_filter_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_filter_value(_value), do: ""

  defp normalize_time_window(value) do
    case parse_positive_int(value, nil) do
      nil -> ""
      hours -> Integer.to_string(hours)
    end
  end

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default

  defp source_inputs(%{"sources" => sources}) when is_list(sources), do: sources

  defp source_inputs(%{"items" => items}) when is_list(items), do: items

  defp source_inputs(%{"feed" => feed}) when is_map(feed), do: [feed]

  defp source_inputs(_snapshot), do: []

  defp ingestion_event?(%{worker: worker}) when is_binary(worker) do
    String.contains?(worker, "Ingestion")
  end

  defp ingestion_event?(_event), do: false

  attr :event, :map, required: true

  defp ingestion_event_detail(assigns) do
    feed = get_in(assigns.event.source_input_snapshot, ["feed"]) || %{}
    items = get_in(assigns.event.source_input_snapshot, ["items"]) || []
    details = assigns.event.change_details || %{}

    assigns =
      assigns
      |> assign(:feed, feed)
      |> assign(:items, items)
      |> assign(:details, details)
      |> assign(:new_items, Enum.filter(items, &(Map.get(&1, "status") == "new")))
      |> assign(:seen_items, Enum.filter(items, &(Map.get(&1, "status") == "seen")))
      |> assign(:error_items, Enum.filter(items, &(Map.get(&1, "status") == "error")))

    ~H"""
    <article
      class="rounded-xl border border-base-300 p-4"
      id={"job-event-#{@event.id}"}
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3 class="text-sm font-semibold">
            Feed Ingestion
          </h3>
          <p class="text-xs text-base-content/60">
            {Map.get(@feed, "origin_provider", "(unknown provider)")} · {Map.get(@feed, "url", "")}
          </p>
        </div>
        <p class="text-xs text-base-content/60">{format_datetime(@event.inserted_at)}</p>
      </div>

      <div class="mt-4 flex flex-wrap gap-3">
        <span class="rounded-full bg-success/15 px-3 py-1 text-xs font-medium text-success">
          {Map.get(@details, "inserted", length(@new_items))} new
        </span>
        <span class="rounded-full bg-base-300/70 px-3 py-1 text-xs font-medium text-base-content/60">
          {Map.get(@details, "seen", length(@seen_items))} already known
        </span>
        <%= if Map.get(@details, "errors", 0) > 0 do %>
          <span class="rounded-full bg-error/15 px-3 py-1 text-xs font-medium text-error">
            {Map.get(@details, "errors", 0)} error(s)
          </span>
        <% end %>
        <%= if @event.error_summary do %>
          <span class="text-xs text-error">{@event.error_summary}</span>
        <% end %>
      </div>

      <%= if @items != [] do %>
        <div class="mt-4 space-y-1" id={"feed-items-#{@event.id}"}>
          <h4 class="text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60">
            Items ({length(@items)})
          </h4>
          <ul class="mt-2 divide-y divide-base-300/50 rounded-xl border border-base-300 bg-base-200/40">
            <%= for item <- @items do %>
              <li class="flex items-start gap-3 px-3 py-2">
                <span class={[
                  "mt-0.5 shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold leading-none",
                  Map.get(item, "status") == "new" &&
                    "bg-success/20 text-success",
                  Map.get(item, "status") == "seen" &&
                    "bg-base-300/60 text-base-content/50",
                  Map.get(item, "status") == "error" &&
                    "bg-error/20 text-error",
                  Map.get(item, "status") not in ["new", "seen", "error"] &&
                    "bg-base-300/60 text-base-content/50"
                ]}>
                  {Map.get(item, "status", "?")}
                </span>
                <div class="min-w-0">
                  <p class="text-xs font-medium leading-snug">
                    {Map.get(item, "title", "(no title)")}
                  </p>
                  <p class="break-all text-[11px] text-base-content/50 leading-snug">
                    {Map.get(item, "url", "")}
                  </p>
                </div>
              </li>
            <% end %>
          </ul>
        </div>
      <% else %>
        <p class="mt-3 text-xs text-base-content/50 italic">
          No item detail recorded (jobs run before this update will show blank here).
        </p>
      <% end %>
    </article>
    """
  end

  attr :event, :map, required: true

  defp editorial_event_detail(assigns) do
    ~H"""
    <article class="rounded-xl border border-base-300 p-4" id={"job-event-#{@event.id}"}>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h3 class="text-sm font-semibold uppercase tracking-[0.14em] text-base-content/70">
          {@event.decision_action}
        </h3>
        <p class="text-xs text-base-content/60">{format_datetime(@event.inserted_at)}</p>
      </div>

      <p class="mt-2 text-sm">{@event.change_summary || "No change summary"}</p>

      <%= if @event.error_summary do %>
        <p class="mt-2 text-sm text-error">Error: {@event.error_summary}</p>
      <% end %>

      <div class="mt-4 grid gap-4 lg:grid-cols-3">
        <div>
          <h4 class="text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60">
            Source Inputs
          </h4>
          <ul class="mt-2 space-y-2 text-xs" id={"source-inputs-#{@event.id}"}>
            <%= for input <- source_inputs(@event.source_input_snapshot) do %>
              <li class="rounded-md bg-base-200/70 p-2">
                <p class="font-medium break-all">
                  {Map.get(input, "headline", Map.get(input, "title", "(no headline)"))}
                </p>
                <p class="break-all text-base-content/70">
                  {Map.get(input, "url", "(no url)")}
                </p>
                <p class="text-base-content/60">
                  {Map.get(input, "excerpt", Map.get(input, "summary", ""))}
                </p>
              </li>
            <% end %>
          </ul>
        </div>

        <div>
          <h4 class="text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60">
            Decision Details
          </h4>
          <ul class="mt-2 space-y-2 text-xs" id={"decision-details-#{@event.id}"}>
            <li class="rounded-md bg-base-200/70 p-2">Action: {@event.decision_action}</li>
            <li class="rounded-md bg-base-200/70 p-2">State: {@event.state}</li>
            <li class="rounded-md bg-base-200/70 p-2">Attempt: {@event.attempt}</li>
            <li class="rounded-md bg-base-200/70 p-2">
              Article: {@event.permanent_article_id || "none"}
            </li>
          </ul>
        </div>

        <div>
          <h4 class="text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60">
            Change Details
          </h4>
          <pre
            class="mt-2 max-h-56 overflow-auto rounded-md bg-base-200/70 p-2 text-[11px] leading-5"
            id={"change-details-#{@event.id}"}
          >{inspect(@event.change_details, pretty: true, limit: :infinity)}</pre>
        </div>
      </div>
    </article>
    """
  end

  defp format_datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  defp format_datetime(_datetime), do: "-"

  defp empty_page do
    %{entries: [], page: 1, per_page: @per_page, total_count: 0, total_pages: 1}
  end

  defp refresh_page(socket),
    do: push_patch(socket, to: jobs_path(socket.assigns.query_params, %{}))
end
