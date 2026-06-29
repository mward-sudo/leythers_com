defmodule LeythersComWeb.Admin.JobOperationsLive do
  @moduledoc """
  Authenticated admin panel showing all job buckets simultaneously with
  live updates, compact card layout, and per-job diagnostics drill-down.
  """

  use LeythersComWeb, :live_view

  alias LeythersCom.Ingestion
  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.JobOperationsUpdates

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
     |> assign(:active_jobs, [])
     |> assign(:queued_jobs, [])
     |> assign(:terminal_page, empty_page())
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
    page = parse_positive_int(params["page"], @default_page)
    filters = normalize_filters(params)
    terminal_opts = Map.merge(filters, %{page: page, per_page: @per_page})

    active_jobs = Intelligence.list_jobs_by_bucket(:active, filters)
    queued_jobs = Intelligence.list_jobs_by_bucket(:queued, filters)
    terminal_page = Intelligence.list_job_operations_jobs("terminal", terminal_opts)
    bucket_counts = Intelligence.job_operations_bucket_counts(filters)

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
      |> Map.take(["page", "queue", "worker", "state", "time_window_hours", "job_id"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    socket
    |> assign(:query_params, query_params)
    |> assign(:filters, filters)
    |> assign(:active_jobs, active_jobs)
    |> assign(:queued_jobs, queued_jobs)
    |> assign(:terminal_page, terminal_page)
    |> assign(:bucket_counts, bucket_counts)
    |> assign(:selected_job_detail, selected_job_detail)
    |> assign(:filters_form, to_form(filters, as: :filters))
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => filters}, socket) do
    params = filters |> normalize_filters() |> Map.put("page", "1")
    {:noreply, push_patch(socket, to: ~p"/admin/jobs?#{params}")}
  end

  @impl true
  def handle_event("regenerate-all", _params, socket) do
    {:ok, %{requeued_sources: n}} = Ingestion.enqueue_article_regeneration(:all)

    {:noreply,
     socket
     |> put_flash(:info, "Queued full regeneration and re-queued #{n} source(s).")
     |> refresh_page()}
  end

  @impl true
  def handle_event("regenerate-recent", _params, socket) do
    {:ok, %{requeued_sources: n}} = Ingestion.enqueue_article_regeneration(:recent)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Queued recent regeneration (last 2 weeks) and re-queued #{n} source(s)."
     )
     |> refresh_page()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto px-4 py-6 sm:px-6 xl:px-8" id="job-operations-page">
        <%!-- Header --%>
        <div class="mb-5 flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Job Operations</h1>
            <p class="mt-0.5 text-sm text-base-content/60">
              All buckets · live updates · click any job to inspect diagnostics
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.link navigate={~p"/admin/overview"} class="btn btn-outline btn-sm">Overview</.link>
            <button
              id="regenerate-recent-button"
              type="button"
              class="btn btn-outline btn-sm"
              phx-click="regenerate-recent"
            >
              Regen Recent
            </button>
            <button
              id="regenerate-all-button"
              type="button"
              class="btn btn-primary btn-sm"
              phx-click="regenerate-all"
            >
              Regen All
            </button>
            <.link navigate={~p"/admin/articles/new"} class="btn btn-primary btn-soft btn-sm">
              Manual Publish
            </.link>
          </div>
        </div>

        <%!-- Filters --%>
        <div
          class="rounded-2xl border border-base-300 bg-base-100 px-4 py-3 shadow-sm"
          id="job-filters"
        >
          <.form for={@filters_form} id="job-filters-form" phx-change="apply_filters">
            <div class="flex flex-wrap items-end gap-3">
              <div class="w-36">
                <.input
                  field={@filters_form[:queue]}
                  type="select"
                  label="Queue"
                  options={[{"All queues", ""} | Enum.map(@filter_options.queues, &{&1, &1})]}
                />
              </div>
              <div class="w-36">
                <.input
                  field={@filters_form[:state]}
                  type="select"
                  label="State"
                  options={[{"All states", ""} | Enum.map(@filter_options.states, &{&1, &1})]}
                />
              </div>
              <div class="w-36">
                <.input
                  field={@filters_form[:time_window_hours]}
                  type="select"
                  label="Time window"
                  options={@time_window_options}
                />
              </div>
              <div class="w-52">
                <.input
                  field={@filters_form[:worker]}
                  type="text"
                  label="Worker"
                  placeholder="e.g. SourceEditorialWorker"
                />
              </div>
              <%= if filters_active?(@filters) do %>
                <.link
                  patch={~p"/admin/jobs"}
                  id="clear-filters-link"
                  class="mb-1 text-xs text-primary underline underline-offset-2"
                >
                  Clear filters
                </.link>
              <% end %>
            </div>
          </.form>
        </div>

        <%!-- Job columns (stacked) --%>
        <div class="mt-5 grid gap-4" id="job-columns">
          <%!-- Active --%>
          <div class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm" id="col-active">
            <div class="mb-3 flex items-center gap-2">
              <span class="h-2 w-2 animate-pulse rounded-full bg-blue-500"></span>
              <h2 class="font-semibold">Active</h2>
              <span class="ml-auto rounded-full bg-blue-100 px-2 py-0.5 text-xs font-semibold text-blue-700">
                {@bucket_counts.active}
              </span>
            </div>
            <%= if @active_jobs == [] do %>
              <p class="rounded-lg border border-dashed border-base-300 px-3 py-6 text-center text-xs text-base-content/50">
                No active jobs
              </p>
            <% else %>
              <div class="space-y-2">
                <%= for job <- @active_jobs do %>
                  <.job_card
                    job={job}
                    params={@query_params}
                    selected={job_selected?(@selected_job_detail, job.id)}
                  />
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Queued --%>
          <div class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm" id="col-queued">
            <div class="mb-3 flex items-center gap-2">
              <span class="h-2 w-2 rounded-full bg-amber-400"></span>
              <h2 class="font-semibold">Queued</h2>
              <span class="ml-auto rounded-full bg-amber-100 px-2 py-0.5 text-xs font-semibold text-amber-700">
                {@bucket_counts.queued}
              </span>
            </div>
            <%= if @queued_jobs == [] do %>
              <p class="rounded-lg border border-dashed border-base-300 px-3 py-6 text-center text-xs text-base-content/50">
                No queued jobs
              </p>
            <% else %>
              <div class="space-y-2">
                <%= for job <- @queued_jobs do %>
                  <.job_card
                    job={job}
                    params={@query_params}
                    selected={job_selected?(@selected_job_detail, job.id)}
                  />
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Terminal --%>
          <div
            class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm"
            id="col-terminal"
          >
            <div class="mb-3 flex items-center gap-2">
              <span class="h-2 w-2 rounded-full bg-base-400"></span>
              <h2 class="font-semibold">Completed / Terminal</h2>
              <span class="ml-auto rounded-full bg-base-200 px-2 py-0.5 text-xs font-semibold text-base-content/60">
                {@bucket_counts.terminal}
              </span>
            </div>
            <%= if @terminal_page.entries == [] do %>
              <p class="rounded-lg border border-dashed border-base-300 px-3 py-6 text-center text-xs text-base-content/50">
                No completed jobs
              </p>
            <% else %>
              <div class="space-y-2">
                <%= for job <- @terminal_page.entries do %>
                  <.job_card
                    job={job}
                    params={@query_params}
                    selected={job_selected?(@selected_job_detail, job.id)}
                  />
                <% end %>
              </div>
              <div class="mt-3 flex items-center justify-between" id="terminal-pagination">
                <.link
                  patch={
                    jobs_path(@query_params, %{
                      page: to_string(max(@terminal_page.page - 1, 1)),
                      job_id: nil
                    })
                  }
                  class={[
                    "btn btn-xs btn-outline",
                    @terminal_page.page <= 1 && "btn-disabled pointer-events-none opacity-50"
                  ]}
                >
                  ← Prev
                </.link>
                <span class="text-xs text-base-content/60">
                  {@terminal_page.page} / {@terminal_page.total_pages}
                </span>
                <.link
                  patch={
                    jobs_path(@query_params, %{
                      page: to_string(min(@terminal_page.page + 1, @terminal_page.total_pages)),
                      job_id: nil
                    })
                  }
                  class={[
                    "btn btn-xs btn-outline",
                    @terminal_page.page >= @terminal_page.total_pages &&
                      "btn-disabled pointer-events-none opacity-50"
                  ]}
                >
                  Next →
                </.link>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Detail modal (popover) --%>
        <%= if not is_nil(@selected_job_detail) do %>
          <%!-- Backdrop --%>
          <div
            id="detail-modal-backdrop"
            class="fixed inset-0 z-40 bg-black/30"
            phx-click={JS.patch(jobs_path(@query_params, %{job_id: nil}))}
          >
          </div>

          <%!-- Modal panel --%>
          <div
            class="fixed inset-y-0 right-0 z-50 w-full overflow-y-auto bg-base-100 shadow-2xl sm:max-w-xl md:max-w-2xl"
            id="job-detail"
          >
            <div class="sticky top-0 flex items-center justify-between border-b border-base-300 bg-base-100 px-6 py-4">
              <div>
                <h2 class="text-lg font-semibold">Diagnostics</h2>
                <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-base-content/60">
                  <span class="font-mono">Job ##{@selected_job_detail.job.id}</span>
                  <span>·</span>
                  <span>{@selected_job_detail.job.worker}</span>
                  <span>·</span>
                  <span class={[
                    "rounded-full px-2 py-0.5 text-[11px] font-semibold",
                    state_badge_class(to_string(@selected_job_detail.job.state))
                  ]}>
                    {@selected_job_detail.job.state}
                  </span>
                </div>
              </div>
              <.link
                patch={jobs_path(@query_params, %{job_id: nil})}
                class="ml-4 flex h-8 w-8 items-center justify-center text-base-content/40 hover:text-base-content"
              >
                <span class="text-xl">×</span>
              </.link>
            </div>

            <div class="p-6">
              <%= if @selected_job_detail.events == [] do %>
                <p class="rounded-xl border border-dashed border-warning/40 bg-warning/10 px-4 py-3 text-sm">
                  No persisted diagnostics events found for this job.
                </p>
              <% else %>
                <div class="space-y-5">
                  <%= for event <- @selected_job_detail.events do %>
                    <%= if ingestion_event?(event) do %>
                      <.ingestion_event_detail event={event} />
                    <% else %>
                      <.editorial_event_detail event={event} />
                    <% end %>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ── Job card ──────────────────────────────────────────────────────────────────

  attr :job, :map, required: true
  attr :params, :map, required: true
  attr :selected, :boolean, default: false

  defp job_card(assigns) do
    ~H"""
    <div
      id={"job-card-#{@job.id}"}
      class={[
        "rounded-lg border px-3 py-2.5 transition-colors",
        @selected && "border-primary bg-primary/5",
        not @selected && "border-base-300 hover:border-base-400/60 hover:bg-base-200/30"
      ]}
    >
      <div class="flex items-start gap-2">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-1.5">
            <span class={[
              "rounded-full px-1.5 py-0.5 text-[10px] font-semibold leading-none",
              state_badge_class(to_string(@job.state))
            ]}>
              {@job.state}
            </span>
            <span class="text-[11px] text-base-content/50">{@job.queue}</span>
          </div>
          <p class="mt-1 text-sm font-medium leading-snug">
            {worker_short_name(@job.worker)}
          </p>
          <p class="mt-0.5 text-[11px] text-base-content/50">
            attempt {@job.attempt} · {format_datetime(@job.inserted_at)}
          </p>
        </div>
        <.link
          patch={jobs_path(@params, %{job_id: to_string(@job.id)})}
          id={"job-view-#{@job.id}"}
          class="btn btn-xs btn-ghost mt-0.5 shrink-0"
        >
          Details
        </.link>
      </div>
    </div>
    """
  end

  # ── Ingestion event ───────────────────────────────────────────────────────────

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
    <article class="rounded-xl border border-base-300 p-4" id={"job-event-#{@event.id}"}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 class="text-sm font-semibold">Feed Ingestion</h3>
          <p class="break-all text-xs text-base-content/60">
            {Map.get(@feed, "origin_provider", "(unknown provider)")} · {Map.get(@feed, "url", "")}
          </p>
        </div>
        <p class="shrink-0 text-xs text-base-content/50">{format_datetime(@event.inserted_at)}</p>
      </div>

      <div class="mt-3 flex flex-wrap gap-2">
        <span class="rounded-full bg-success/15 px-2.5 py-1 text-xs font-medium text-success">
          {Map.get(@details, "inserted", length(@new_items))} new
        </span>
        <span class="rounded-full bg-base-300/70 px-2.5 py-1 text-xs font-medium text-base-content/60">
          {Map.get(@details, "seen", length(@seen_items))} already known
        </span>
        <%= if Map.get(@details, "errors", 0) > 0 do %>
          <span class="rounded-full bg-error/15 px-2.5 py-1 text-xs font-medium text-error">
            {Map.get(@details, "errors", 0)} error(s)
          </span>
        <% end %>
        <%= if @event.error_summary do %>
          <span class="text-xs text-error">{@event.error_summary}</span>
        <% end %>
      </div>

      <%= if @items != [] do %>
        <div class="mt-4" id={"feed-items-#{@event.id}"}>
          <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Items ({length(@items)})
          </h4>
          <ul class="mt-2 max-h-72 divide-y divide-base-300/50 overflow-y-auto rounded-xl border border-base-300 bg-base-200/40">
            <%= for item <- @items do %>
              <li class="flex items-start gap-3 px-3 py-2">
                <span class={[
                  "mt-0.5 shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-semibold leading-none",
                  Map.get(item, "status") == "new" && "bg-success/20 text-success",
                  Map.get(item, "status") == "seen" && "bg-base-300/60 text-base-content/50",
                  Map.get(item, "status") == "error" && "bg-error/20 text-error",
                  Map.get(item, "status") not in ["new", "seen", "error"] &&
                    "bg-base-300/60 text-base-content/50"
                ]}>
                  {Map.get(item, "status", "?")}
                </span>
                <div class="min-w-0">
                  <p class="text-xs font-medium leading-snug">
                    {Map.get(item, "title", "(no title)")}
                  </p>
                  <p class="break-all text-[11px] leading-snug text-base-content/50">
                    {Map.get(item, "url", "")}
                  </p>
                </div>
              </li>
            <% end %>
          </ul>
        </div>
      <% else %>
        <p class="mt-3 text-xs italic text-base-content/40">
          No item detail (job ran before per-item tracking was enabled).
        </p>
      <% end %>
    </article>
    """
  end

  # ── Editorial event ───────────────────────────────────────────────────────────

  attr :event, :map, required: true

  defp editorial_event_detail(assigns) do
    ~H"""
    <article class="rounded-xl border border-base-300 p-4" id={"job-event-#{@event.id}"}>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h3 class="text-sm font-semibold uppercase tracking-wider text-base-content/60">
          {@event.decision_action}
        </h3>
        <p class="shrink-0 text-xs text-base-content/50">{format_datetime(@event.inserted_at)}</p>
      </div>

      <p class="mt-2 text-sm">{@event.change_summary || "No change summary"}</p>

      <%= if @event.error_summary do %>
        <p class="mt-1 text-sm text-error">Error: {@event.error_summary}</p>
      <% end %>

      <div class="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">Sources</h4>
          <ul class="mt-2 space-y-2 text-xs" id={"source-inputs-#{@event.id}"}>
            <%= for input <- source_inputs(@event.source_input_snapshot) do %>
              <li class="rounded-md bg-base-200/70 p-2">
                <p class="font-medium">
                  {Map.get(input, "headline", Map.get(input, "title", "(no headline)"))}
                </p>
                <p class="mt-0.5 break-all text-base-content/60">
                  {Map.get(input, "url", "(no url)")}
                </p>
                <p class="text-base-content/50">
                  {Map.get(input, "excerpt", Map.get(input, "summary", ""))}
                </p>
              </li>
            <% end %>
          </ul>
        </div>

        <div>
          <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Decision
          </h4>
          <ul class="mt-2 space-y-1.5 text-xs" id={"decision-details-#{@event.id}"}>
            <li class="rounded-md bg-base-200/70 px-2 py-1">Action: {@event.decision_action}</li>
            <li class="rounded-md bg-base-200/70 px-2 py-1">State: {@event.state}</li>
            <li class="rounded-md bg-base-200/70 px-2 py-1">Attempt: {@event.attempt}</li>
            <li class="rounded-md bg-base-200/70 px-2 py-1">
              Article: {@event.permanent_article_id || "none"}
            </li>
          </ul>
        </div>

        <div class="sm:col-span-2 lg:col-span-1">
          <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">Details</h4>
          <pre
            class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all rounded-md bg-base-200/70 p-2 text-[11px] leading-5"
            id={"change-details-#{@event.id}"}
          >{inspect(@event.change_details, pretty: true, limit: :infinity)}</pre>
        </div>
      </div>
    </article>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

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

  defp job_selected?(nil, _job_id), do: false

  defp job_selected?(%{job: job}, job_id) do
    Map.get(job, :id) == job_id
  end

  defp worker_short_name(nil), do: "(unknown)"
  defp worker_short_name(worker), do: worker |> String.split(".") |> List.last()

  defp state_badge_class(state) do
    case state do
      "executing" -> "bg-blue-100 text-blue-700"
      "available" -> "bg-amber-100 text-amber-700"
      "scheduled" -> "bg-amber-100 text-amber-700"
      "retryable" -> "bg-orange-100 text-orange-700"
      "completed" -> "bg-green-100 text-green-700"
      "discarded" -> "bg-red-100 text-red-700"
      "cancelled" -> "bg-base-200 text-base-content/50"
      _ -> "bg-base-200 text-base-content/50"
    end
  end

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

  defp filters_active?(filters) do
    Enum.any?(filters, fn {_k, v} -> v != "" end)
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

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(_), do: "-"

  defp empty_page do
    %{entries: [], page: 1, per_page: @per_page, total_count: 0, total_pages: 1}
  end

  defp refresh_page(socket) do
    push_patch(socket, to: jobs_path(socket.assigns.query_params, %{}))
  end
end
