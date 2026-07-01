defmodule LeythersComWeb.Admin.JobOperationsLive do
  @moduledoc """
  Authenticated admin panel showing process-centric job operations timeline.
  Processes are top-level items (ingestion runs, editorial reviews) with drill-down
  to individual events and full LLM prompt/output visibility.
  """

  use LeythersComWeb, :live_view

  alias LeythersCom.Ingestion
  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.JobOperationsUpdates

  @default_page 1
  @per_page 20
  @refresh_interval_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(LeythersCom.PubSub, JobOperationsUpdates.topic())
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Job Operations")
     |> assign(:query_params, %{})
     |> assign(:processes_page, empty_page())
     |> assign(:expanded_process_id, nil)
     |> assign(:process_events, [])
     |> assign(:pending_sources, [])
     |> assign(:progress_snapshot, %{
       running_jobs: 0,
       queued_jobs: 0,
       pending_sources: 0,
       left_to_run: 0
     })
     |> assign(
       :live_activity,
       %{
         active_now: ["none"],
         up_next: ["none"],
         more_up_next: 0,
         queue_context: "0 running, 0 queued, 0 pending"
       }
     )
     |> assign(:live_activity_text, "Active now: none | Up next: none")
     |> assign(:log_popover_open, false)
     |> assign(:log_entries, [])
     |> assign(:selected_event_id, nil)
     |> assign(:selected_event, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_page(socket, params)}
  end

  @impl true
  def handle_info({:job_operations, :updated}, socket) do
    {:noreply, load_page(socket, socket.assigns.query_params)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_page(socket, socket.assigns.query_params)}
  end

  defp load_page(socket, params) do
    page = parse_positive_int(params["page"], @default_page)
    opts = %{page: page, per_page: @per_page}

    processes_page = Intelligence.list_processes(opts)

    expanded_process_id = params["process_id"]

    process_events =
      if expanded_process_id, do: Intelligence.process_events(expanded_process_id), else: []

    # For executing editorial jobs, fetch pending sources being processed
    pending_sources =
      if expanded_process_id && String.starts_with?(expanded_process_id, "oban-") do
        Intelligence.pending_editorial_sources(100)
      else
        []
      end

    selected_event_id = params["event_id"]

    selected_event =
      if selected_event_id do
        Enum.find(process_events, &(to_string(&1.id) == selected_event_id))
      else
        nil
      end

    progress_snapshot = Intelligence.job_operations_progress_snapshot()
    live_pending_sources = Intelligence.pending_editorial_sources(3)

    # Fetch recent events from running processes to show detailed LLM operations in log
    recent_process_events =
      if expanded_process_id do
        process_events
      else
        # Get events from the most recently active processes for detailed log display
        processes_page.entries
        |> Enum.take(5)
        |> Enum.flat_map(&Intelligence.process_events(&1.process_run_id))
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
        |> Enum.take(20)
      end

    live_activity =
      build_live_activity(progress_snapshot, processes_page.entries, live_pending_sources)

    live_activity_text =
      "Active now: #{Enum.join(live_activity.active_now, ", ")} | Up next: #{Enum.join(live_activity.up_next, ", ")}"

    log_entries =
      build_log_entries(
        progress_snapshot,
        processes_page.entries,
        recent_process_events,
        live_pending_sources
      )

    query_params =
      params
      |> Map.take(["page", "process_id", "event_id"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    socket
    |> assign(:query_params, query_params)
    |> assign(:processes_page, processes_page)
    |> assign(:expanded_process_id, expanded_process_id)
    |> assign(:process_events, process_events)
    |> assign(:pending_sources, pending_sources)
    |> assign(:progress_snapshot, progress_snapshot)
    |> assign(:live_activity, live_activity)
    |> assign(:live_activity_text, live_activity_text)
    |> assign(:log_entries, log_entries)
    |> assign(:selected_event_id, selected_event_id)
    |> assign(:selected_event, selected_event)
  end

  defp build_live_activity(progress_snapshot, processes, live_pending_sources) do
    running_jobs = progress_snapshot.running_jobs || 0
    queued_jobs = progress_snapshot.queued_jobs || 0
    pending_sources_count = progress_snapshot.pending_sources || 0

    active_process_labels =
      processes
      |> Enum.filter(&(&1.status == :running))
      |> Enum.map(&process_label/1)
      |> Enum.uniq()

    pending_source_labels = Enum.map(live_pending_sources, &source_label/1)
    more_up_next = max(pending_sources_count - length(pending_source_labels), 0)

    %{
      active_now: if(active_process_labels == [], do: ["none"], else: active_process_labels),
      up_next: if(pending_source_labels == [], do: ["none"], else: pending_source_labels),
      more_up_next: more_up_next,
      queue_context:
        "#{running_jobs} running, #{queued_jobs} queued, #{pending_sources_count} pending"
    }
  end

  defp process_label(process) do
    name = Map.get(process, :process_name, "process")
    run_id = Map.get(process, :process_run_id)
    "#{name} [run #{short_id(run_id)}]"
  end

  defp source_label(source) do
    title = Map.get(source, :title, "untitled source")
    source_id = Map.get(source, :id)
    "#{title} [src #{short_id(source_id)}]"
  end

  defp short_id(nil), do: "n/a"

  defp short_id(id) when is_binary(id) do
    cond do
      String.valid?(id) ->
        String.slice(id, 0, 8)

      byte_size(id) == 16 ->
        case Ecto.UUID.load(id) do
          {:ok, uuid} -> String.slice(uuid, 0, 8)
          :error -> id |> Base.encode16(case: :lower) |> String.slice(0, 8)
        end

      true ->
        id |> Base.encode16(case: :lower) |> String.slice(0, 8)
    end
  end

  defp short_id(id), do: id |> inspect() |> String.slice(0, 8)

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  @impl true
  def handle_event("expand_process", %{"process_id" => process_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/jobs?process_id=#{process_id}")}
  end

  @impl true
  def handle_event("collapse_process", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/jobs")}
  end

  @impl true
  def handle_event("show_event", %{"event_id" => event_id}, socket) do
    process_id = socket.assigns.expanded_process_id

    {:noreply,
     push_patch(socket, to: ~p"/admin/jobs?process_id=#{process_id}&event_id=#{event_id}")}
  end

  @impl true
  def handle_event("toggle-live-log", _params, socket) do
    {:noreply, assign(socket, :log_popover_open, !socket.assigns.log_popover_open)}
  end

  @impl true
  def handle_event("regenerate-all", _params, socket) do
    {:ok, %{cancelled_jobs: cancelled_count}} = Intelligence.cancel_all_jobs()
    {:ok, %{requeued_sources: n}} = Ingestion.enqueue_article_regeneration(:all)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Cancelled #{cancelled_count} job(s). Queued full regeneration and re-queued #{n} source(s)."
     )
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
      <div class="w-full px-4 py-6 sm:px-6 xl:px-8" id="job-operations-page">
        <%!-- Header --%>
        <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Job Operations</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Ingestion runs and editorial reviews · click to drill down
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.link navigate={~p"/admin/overview"} class="btn btn-outline btn-sm">
              <.icon name="hero-arrow-left" class="h-4 w-4" /> Overview
            </.link>
            <button
              id="regenerate-recent-button"
              type="button"
              class="btn btn-outline btn-sm"
              phx-click="regenerate-recent"
            >
              <.icon name="hero-arrow-path" class="h-4 w-4" /> Regen Recent
            </button>
            <button
              id="regenerate-all-button"
              type="button"
              class="btn btn-primary btn-sm"
              phx-click="regenerate-all"
            >
              <.icon name="hero-arrow-path" class="h-4 w-4" /> Regen All
            </button>
            <.link navigate={~p"/admin/articles/new"} class="btn btn-primary btn-soft btn-sm">
              <.icon name="hero-plus" class="h-4 w-4" /> Publish
            </.link>
          </div>
        </div>

        <div id="job-progress-summary" class="mb-6 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-xl border border-base-300 bg-base-100 px-4 py-3 shadow-sm">
            <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">
              Running now
            </p>
            <p class="mt-1 text-2xl font-bold text-base-content">{@progress_snapshot.running_jobs}</p>
          </div>
          <div class="rounded-xl border border-base-300 bg-base-100 px-4 py-3 shadow-sm">
            <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">
              Left to run
            </p>
            <p class="mt-1 text-2xl font-bold text-base-content">{@progress_snapshot.left_to_run}</p>
          </div>
          <div class="rounded-xl border border-base-300 bg-base-100 px-4 py-3 shadow-sm">
            <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">
              Queued jobs
            </p>
            <p class="mt-1 text-2xl font-bold text-base-content">{@progress_snapshot.queued_jobs}</p>
          </div>
          <div class="rounded-xl border border-base-300 bg-base-100 px-4 py-3 shadow-sm">
            <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">
              Pending sources
            </p>
            <p class="mt-1 text-2xl font-bold text-base-content">
              {@progress_snapshot.pending_sources}
            </p>
          </div>
        </div>

        <section
          id="job-progress-description"
          class="mb-6 rounded-xl border border-base-300 bg-base-100 px-4 py-3 shadow-sm"
        >
          <div class="mb-2 flex items-center justify-between gap-2">
            <p class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Live Activity
            </p>
            <p class="text-xs text-base-content/50">{@live_activity.queue_context}</p>
          </div>

          <div class="space-y-2 text-sm">
            <div class="flex flex-col gap-1 sm:flex-row sm:items-start sm:gap-2">
              <p class="min-w-20 text-xs font-medium uppercase tracking-wider text-base-content/50">
                Active now
              </p>
              <p class="text-base-content/80">{Enum.join(@live_activity.active_now, ", ")}</p>
            </div>

            <div class="flex flex-col gap-1 sm:flex-row sm:items-start sm:gap-2">
              <p class="min-w-20 text-xs font-medium uppercase tracking-wider text-base-content/50">
                Up next
              </p>
              <p class="text-base-content/80">
                {Enum.join(@live_activity.up_next, ", ")}
                <%= if @live_activity.more_up_next > 0 do %>
                  <span class="text-base-content/60"> (+{@live_activity.more_up_next} more)</span>
                <% end %>
              </p>
            </div>
          </div>
        </section>

        <%!-- Process Timeline --%>
        <div class="space-y-3" id="process-timeline">
          <%= if @processes_page.entries == [] do %>
            <div class="rounded-2xl border-2 border-dashed border-base-300 bg-base-100/50 px-6 py-12 text-center">
              <div class="text-base-content/40">
                <.icon name="hero-check-circle" class="mx-auto h-12 w-12 opacity-30" />
              </div>
              <p class="mt-2 text-sm font-medium text-base-content/60">No processes yet</p>
              <p class="mt-1 text-xs text-base-content/40">
                Ingestion runs and editorial reviews will appear here as they execute.
              </p>
            </div>
          <% else %>
            <%= for process <- @processes_page.entries do %>
              <.process_card
                process={process}
                expanded={@expanded_process_id == process.process_run_id}
                events={@process_events}
                pending_sources={@pending_sources}
                selected_event_id={@selected_event_id}
              />
            <% end %>

            <%!-- Pagination --%>
            <div class="mt-6 flex items-center justify-center gap-3">
              <.link
                patch={
                  jobs_path(@query_params, %{
                    page: to_string(max(@processes_page.page - 1, 1)),
                    process_id: nil,
                    event_id: nil
                  })
                }
                class={[
                  "btn btn-sm btn-outline",
                  @processes_page.page <= 1 && "btn-disabled pointer-events-none opacity-50"
                ]}
              >
                <.icon name="hero-chevron-left" class="h-4 w-4" /> Previous
              </.link>
              <span class="text-sm text-base-content/60">
                Page {@processes_page.page} of {@processes_page.total_pages}
              </span>
              <.link
                patch={
                  jobs_path(@query_params, %{
                    page: to_string(min(@processes_page.page + 1, @processes_page.total_pages)),
                    process_id: nil,
                    event_id: nil
                  })
                }
                class={[
                  "btn btn-sm btn-outline",
                  @processes_page.page >= @processes_page.total_pages &&
                    "btn-disabled pointer-events-none opacity-50"
                ]}
              >
                Next <.icon name="hero-chevron-right" class="h-4 w-4" />
              </.link>
            </div>
          <% end %>
        </div>

        <%!-- Live Log Popover --%>
        <div class="fixed bottom-4 right-4 z-40 flex flex-col items-end gap-2">
          <button
            id="toggle-live-log"
            type="button"
            class="btn btn-primary btn-sm shadow-lg"
            phx-click="toggle-live-log"
          >
            <.icon name="hero-command-line" class="h-4 w-4" />
            {if @log_popover_open, do: "Hide Live Log", else: "Live Log"}
          </button>

          <%= if @log_popover_open do %>
            <section
              id="live-log-popover"
              class="w-[min(92vw,44rem)] rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
            >
              <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                    Live Log
                  </p>
                  <p class="text-xs text-base-content/50">
                    Auto-follows while you stay at the bottom.
                  </p>
                </div>
                <span class="text-xs text-base-content/50">{@live_activity.queue_context}</span>
              </div>

              <div
                id="live-log-entries"
                phx-hook="LogTail"
                class="max-h-80 overflow-y-auto px-4 py-3"
              >
                <div class="space-y-1.5 font-mono text-xs leading-relaxed">
                  <%= for entry <- @log_entries do %>
                    <p class="text-base-content/80">
                      <span class="text-base-content/50">[{format_log_time(entry.timestamp)}]</span>
                      <span class="font-semibold text-base-content/60">{entry.category}</span>
                      <span>{entry.message}</span>
                    </p>
                  <% end %>

                  <%= if @log_entries == [] do %>
                    <p class="text-base-content/50">No activity yet.</p>
                  <% end %>
                </div>
              </div>
            </section>
          <% end %>
        </div>

        <%!-- Event Detail Modal --%>
        <%= if not is_nil(@selected_event) do %>
          <div
            id="event-detail-backdrop"
            class="fixed inset-0 z-40 bg-black/30"
            phx-click={JS.patch(jobs_path(@query_params, %{event_id: nil}))}
          >
          </div>
          <div
            class="fixed inset-y-0 right-0 z-50 w-full overflow-y-auto bg-base-100 shadow-2xl sm:max-w-xl md:max-w-2xl"
            id="event-detail"
          >
            <div class="sticky top-0 flex items-center justify-between border-b border-base-300 bg-base-100 px-6 py-4">
              <div>
                <h2 class="text-lg font-semibold">Event Details</h2>
                <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-base-content/60">
                  <span>Event #{String.slice(@selected_event.id, 0..7)}</span>
                  <span>·</span>
                  <span>{format_datetime(@selected_event.inserted_at)}</span>
                </div>
              </div>
              <.link
                patch={jobs_path(@query_params, %{event_id: nil})}
                class="flex h-8 w-8 items-center justify-center text-base-content/40 hover:text-base-content"
              >
                <.icon name="hero-x-mark" class="h-5 w-5" />
              </.link>
            </div>
            <div class="p-6">
              <%= if ingestion_event?(@selected_event) do %>
                <.ingestion_event_detail event={@selected_event} />
              <% else %>
                <.editorial_event_detail event={@selected_event} />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ── Process Card ──────────────────────────────────────────────────────────────

  attr :process, :map, required: true
  attr :expanded, :boolean, default: false
  attr :events, :list, default: []
  attr :pending_sources, :list, default: []
  attr :selected_event_id, :string, default: nil

  defp process_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 shadow-sm transition-all">
      <button
        id={"process-#{@process.process_run_id}"}
        type="button"
        class="w-full px-5 py-4 text-left hover:bg-base-200/30"
        phx-click="expand_process"
        phx-value-process_id={@process.process_run_id}
      >
        <div class="flex items-start justify-between gap-4">
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <.icon
                name={
                  case @process.process_type do
                    :ingestion -> "hero-arrow-down-tray"
                    :editorial -> "hero-pencil-square"
                    _ -> "hero-cog"
                  end
                }
                class="h-5 w-5 flex-shrink-0"
              />
              <h3 class="text-base font-semibold">{@process.process_name}</h3>
              <span class={[
                "ml-auto inline-flex items-center rounded-full px-2.5 py-1 text-xs font-medium",
                case @process.status do
                  :running -> "bg-blue-100 text-blue-700"
                  :completed -> "bg-green-100 text-green-700"
                  :failed -> "bg-red-100 text-red-700"
                  :discarded -> "bg-orange-100 text-orange-700"
                  _ -> "bg-base-200 text-base-content/60"
                end
              ]}>
                {atom_to_status_text(@process.status)}
              </span>
            </div>
            <p class="mt-2 text-xs text-base-content/60">
              {format_datetime(@process.started_at)} · {@process.event_count} event(s)
            </p>
          </div>
          <div class="flex items-center gap-1 text-base-content/40">
            <.icon
              name="hero-chevron-down"
              class={["h-5 w-5 transition-transform", @expanded && "rotate-180"]}
            />
          </div>
        </div>
      </button>

      <%= if @expanded do %>
        <div class="border-t border-base-300 px-5 py-4 bg-base-200/20">
          <%= if Map.get(@process, :is_executing) && Enum.count(@pending_sources) > 0 do %>
            <%!-- Show pending sources for executing jobs --%>
            <div class="mb-4 space-y-2">
              <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                Processing ({Enum.count(@pending_sources)} pending source(s))
              </h4>
              <div class="space-y-2">
                <%= for source <- @pending_sources |> Enum.take(10) do %>
                  <div class="rounded-lg border border-base-300 bg-base-100 px-3 py-2.5 text-sm">
                    <p class="font-medium text-base-content">{source.title}</p>
                    <p class="mt-0.5 text-xs text-base-content/60">
                      Added {format_datetime(source.inserted_at)}
                    </p>
                  </div>
                <% end %>
                <%= if Enum.count(@pending_sources) > 10 do %>
                  <p class="text-xs text-base-content/50 italic">
                    +{Enum.count(@pending_sources) - 10} more pending source(s)
                  </p>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if Enum.count(@events) > 0 do %>
            <div class="mb-3 space-y-2">
              <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                Events ({Enum.count(@events)})
              </h4>
              <div class="space-y-1.5">
                <%= for event <- @events do %>
                  <button
                    type="button"
                    class={[
                      "w-full rounded-lg px-3 py-2.5 text-left text-sm transition-colors",
                      @selected_event_id == to_string(event.id) &&
                        "bg-primary/10 border border-primary text-primary-focus",
                      @selected_event_id != to_string(event.id) &&
                        "border border-base-300 hover:bg-base-100"
                    ]}
                    phx-click="show_event"
                    phx-value-event_id={event.id}
                    id={"event-btn-#{event.id}"}
                  >
                    <div class="flex items-start justify-between gap-2">
                      <div>
                        <p class="font-medium">
                          {if(ingestion_event?(event), do: "Feed Ingestion", else: "Editorial Review")}
                        </p>
                        <p class="text-xs text-base-content/60 mt-0.5">
                          {format_datetime(event.inserted_at)}
                        </p>
                      </div>
                      <span class={[
                        "flex-shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-semibold leading-none",
                        case event.state do
                          "completed" -> "bg-green-100 text-green-700"
                          "executing" -> "bg-blue-100 text-blue-700"
                          "retryable" -> "bg-orange-100 text-orange-700"
                          "discarded" -> "bg-red-100 text-red-700"
                          _ -> "bg-base-200 text-base-content/60"
                        end
                      ]}>
                        {event.state}
                      </span>
                    </div>
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Ingestion Event Detail ────────────────────────────────────────────────────

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
    <div class="space-y-5" id={"ingestion-event-#{@event.id}"}>
      <div>
        <h3 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-arrow-down-tray" class="h-5 w-5" /> Feed Ingestion
        </h3>
        <p class="mt-2 break-all text-sm text-base-content/70">
          <span class="font-medium">{Map.get(@feed, "origin_provider", "(unknown)")}</span>
          · {Map.get(@feed, "url", "(no URL)")}
        </p>
      </div>

      <div class="grid grid-cols-3 gap-2">
        <div class="rounded-lg bg-success/10 px-3 py-2">
          <p class="text-xs font-medium text-success">
            {Map.get(@details, "inserted", length(@new_items))} new
          </p>
        </div>
        <div class="rounded-lg bg-base-200 px-3 py-2">
          <p class="text-xs font-medium text-base-content/60">
            {Map.get(@details, "seen", length(@seen_items))} seen
          </p>
        </div>
        <%= if Map.get(@details, "errors", 0) > 0 do %>
          <div class="rounded-lg bg-error/10 px-3 py-2">
            <p class="text-xs font-medium text-error">{Map.get(@details, "errors", 0)} error(s)</p>
          </div>
        <% else %>
          <div class="rounded-lg bg-base-200 px-3 py-2">
            <p class="text-xs font-medium text-base-content/60">0 errors</p>
          </div>
        <% end %>
      </div>

      <%= if @event.error_summary do %>
        <div class="rounded-lg border border-error/30 bg-error/5 px-4 py-3">
          <p class="text-sm text-error font-medium">Error: {@event.error_summary}</p>
        </div>
      <% end %>

      <%= if @items != [] do %>
        <div>
          <h4 class="text-sm font-semibold mb-3">Items ({length(@items)})</h4>
          <div class="max-h-96 overflow-y-auto space-y-2">
            <%= for item <- @items do %>
              <div class="rounded-lg border border-base-300 bg-base-200/30 px-3 py-2.5">
                <div class="flex items-start gap-2">
                  <span class={[
                    "mt-0.5 flex-shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-semibold leading-none",
                    Map.get(item, "status") == "new" && "bg-success/20 text-success",
                    Map.get(item, "status") == "seen" && "bg-base-300/60 text-base-content/50",
                    Map.get(item, "status") == "error" && "bg-error/20 text-error"
                  ]}>
                    {Map.get(item, "status", "?")}
                  </span>
                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium break-words">
                      {Map.get(item, "title", "(no title)")}
                    </p>
                    <p class="text-xs text-base-content/60 break-all mt-1">
                      {Map.get(item, "url", "")}
                    </p>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Editorial Event Detail ────────────────────────────────────────────────────

  attr :event, :map, required: true

  defp editorial_event_detail(assigns) do
    ~H"""
    <div class="space-y-5" id={"editorial-event-#{@event.id}"}>
      <div>
        <h3 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-pencil-square" class="h-5 w-5" /> Editorial Review
        </h3>
        <div class="mt-3 grid gap-2 sm:grid-cols-2">
          <div>
            <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">Decision</p>
            <p class="mt-1 text-sm font-semibold text-base-content">{@event.decision_action}</p>
          </div>
          <div>
            <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">State</p>
            <p class={[
              "mt-1 text-sm font-semibold rounded-full inline-block px-2.5 py-1 text-xs font-medium",
              case @event.state do
                "completed" -> "bg-green-100 text-green-700"
                "executing" -> "bg-blue-100 text-blue-700"
                "retryable" -> "bg-orange-100 text-orange-700"
                "discarded" -> "bg-red-100 text-red-700"
                _ -> "bg-base-200 text-base-content/60"
              end
            ]}>
              {@event.state}
            </p>
          </div>
        </div>

        <%= if @event.llm_prompt do %>
          <div class="mt-3">
            <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">
              LLM operation
            </p>
            <p class="mt-1 text-sm font-semibold text-base-content">{llm_operation_label(@event)}</p>
          </div>
        <% end %>
      </div>

      <%= if @event.change_summary do %>
        <div>
          <p class="text-xs font-medium uppercase tracking-wider text-base-content/50 mb-2">
            Summary
          </p>
          <p class="text-sm text-base-content">{@event.change_summary}</p>
        </div>
      <% end %>

      <%= if @event.error_summary do %>
        <div class="rounded-lg border border-error/30 bg-error/5 px-4 py-3">
          <p class="text-sm text-error font-medium">Error: {@event.error_summary}</p>
        </div>
      <% end %>

      <div>
        <p class="text-xs font-medium uppercase tracking-wider text-base-content/50 mb-3">Sources</p>
        <div class="grid gap-2 sm:grid-cols-2">
          <%= for input <- source_inputs(@event.source_input_snapshot) do %>
            <div class="rounded-lg border border-base-300 bg-base-200/30 p-3">
              <p class="font-medium text-sm">
                {Map.get(input, "headline", Map.get(input, "title", "(no headline)"))}
              </p>
              <p class="text-xs text-base-content/60 mt-1 break-all">{Map.get(input, "url", "")}</p>
              <p class="text-xs text-base-content/50 mt-2">
                {Map.get(input, "excerpt", Map.get(input, "summary", ""))}
              </p>
            </div>
          <% end %>
        </div>
      </div>

      <%= if @event.llm_prompt do %>
        <div>
          <p class="text-xs font-medium uppercase tracking-wider text-base-content/50 mb-2">
            LLM Prompt
          </p>
          <pre class="rounded-lg bg-base-200 p-3 text-xs overflow-x-auto max-h-48 overflow-y-auto border border-base-300"><code>{@event.llm_prompt}</code></pre>
        </div>
      <% end %>

      <%= if @event.llm_output do %>
        <div>
          <p class="text-xs font-medium uppercase tracking-wider text-base-content/50 mb-2">
            LLM Output
          </p>
          <pre class="rounded-lg bg-base-200 p-3 text-xs overflow-x-auto max-h-48 overflow-y-auto border border-base-300"><code>{inspect(@event.llm_output, pretty: true, limit: :infinity)}</code></pre>
        </div>
      <% end %>

      <div>
        <p class="text-xs font-medium uppercase tracking-wider text-base-content/50 mb-2">
          Change Details
        </p>
        <pre class="rounded-lg bg-base-200 p-3 text-xs overflow-x-auto max-h-48 overflow-y-auto border border-base-300"><code>{inspect(@event.change_details, pretty: true, limit: :infinity)}</code></pre>
      </div>
    </div>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default

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

  defp atom_to_status_text(status) do
    case status do
      :running -> "Running"
      :completed -> "Completed"
      :failed -> "Failed"
      :discarded -> "Discarded"
      :mixed -> "Mixed"
      _ -> "Unknown"
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(_), do: "-"

  defp format_log_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_log_time(_), do: "-"

  defp source_inputs(%{"sources" => sources}) when is_list(sources), do: sources
  defp source_inputs(%{"items" => items}) when is_list(items), do: items
  defp source_inputs(%{"feed" => feed}) when is_map(feed), do: [feed]
  defp source_inputs(_snapshot), do: []

  defp build_log_entries(progress_snapshot, processes, process_events, pending_sources) do
    now = DateTime.utc_now()

    snapshot_entry =
      log_entry(
        now,
        "snapshot",
        "#{progress_snapshot.running_jobs || 0} running, #{progress_snapshot.queued_jobs || 0} queued, #{progress_snapshot.pending_sources || 0} pending"
      )

    process_entries =
      processes
      |> Enum.take(8)
      |> Enum.map(fn process ->
        log_entry(
          process.last_updated_at || process.started_at || now,
          "process",
          "#{atom_to_status_text(process.status)} #{process.process_name} [run #{short_id(process.process_run_id)}]"
        )
      end)

    event_entries = build_event_entries(process_events, now)

    pending_entries =
      pending_sources
      |> Enum.take(3)
      |> Enum.map(fn source ->
        log_entry(
          source.inserted_at || now,
          "queue",
          "next source #{source.title} [src #{short_id(source.id)}]"
        )
      end)

    [snapshot_entry | process_entries ++ event_entries ++ pending_entries]
    |> Enum.sort_by(&DateTime.to_unix(&1.timestamp, :microsecond))
    |> Enum.take(-120)
  end

  defp build_event_entries(process_events, now) do
    process_events
    |> Enum.reverse()
    |> Enum.take(10)
    |> Enum.reverse()
    |> Enum.map(&format_event_entry(&1, now))
  end

  defp format_event_entry(event, now) do
    operation = llm_operation_label(event)

    message =
      if operation do
        "#{event.state} #{operation} [event #{short_id(event.id)}]"
      else
        "#{event.state} #{event.decision_action || "updated"} [event #{short_id(event.id)}]"
      end

    log_entry(
      event.inserted_at || now,
      "event",
      message
    )
  end

  defp log_entry(timestamp, category, message) do
    %{
      timestamp: normalize_timestamp(timestamp),
      category: category,
      message: message
    }
  end

  defp normalize_timestamp(%DateTime{} = timestamp), do: timestamp
  defp normalize_timestamp(_), do: DateTime.utc_now()

  defp llm_operation_label(event) do
    # Check change_details for prompt_version (most reliable for LLM operations)
    change_details_to_operation_label(event) ||
      change_summary_to_operation_label(event) ||
      decision_action_to_operation_label(event) ||
      llm_prompt_label(event)
  end

  defp change_details_to_operation_label(%{change_details: details}) when is_map(details) do
    case details do
      %{"prompt_version" => "source_editorial_v1"} ->
        "Generate article draft"

      %{"prompt_version" => "homepage_ranker_v1"} ->
        "Score homepage importance"

      %{"prompt_version" => version} when is_binary(version) ->
        if String.contains?(version, ["comparison", "headline"]) do
          "Compare headlines for same story"
        end

      _ ->
        nil
    end
  end

  defp change_details_to_operation_label(_event), do: nil

  defp change_summary_to_operation_label(%{change_summary: summary}) when is_binary(summary) do
    patterns = [
      {"llm_draft", "Generate article draft"},
      {"significance", "Score homepage importance"},
      {"score", "Score homepage importance"},
      {"headline", "Compare headlines for same story"},
      {"grouping", "Compare headlines for same story"},
      {"clustered", "Cluster and group sources"}
    ]

    Enum.find_value(patterns, fn {pattern, label} ->
      if String.contains?(summary, pattern) do
        label
      end
    end)
  end

  defp change_summary_to_operation_label(_event), do: nil

  defp decision_action_to_operation_label(%{decision_action: action})
       when is_binary(action) and action != "" do
    patterns = [
      {"headline", "Compare headlines for same story"},
      {"grouping", "Compare headlines for same story"},
      {"similar", "Compare headlines for same story"},
      {"draft", "Generate article draft"},
      {"generate", "Generate article draft"},
      {"article", "Generate article draft"},
      {"score", "Score homepage importance"},
      {"importance", "Score homepage importance"},
      {"rank", "Score homepage importance"},
      {"cluster", "Cluster and group sources"},
      {"group", "Cluster and group sources"},
      {"processed", "Publish article"},
      {"published", "Publish article"}
    ]

    Enum.find_value(patterns, fn {pattern, label} ->
      if String.contains?(action, pattern) do
        label
      end
    end)
  end

  defp decision_action_to_operation_label(_event), do: nil

  defp llm_prompt_label(%{llm_prompt: prompt}) when is_binary(prompt) do
    patterns = [
      {"Write a Leythers-style rugby article", "Generate article draft"},
      {"Determine if two rugby headlines describe the same core story event",
       "Compare headlines for same story"},
      {"Score homepage importance from 0 to 100", "Score homepage importance"},
      {"rugby", "Process article"},
      {"article", "Process article"}
    ]

    Enum.find_value(patterns, fn {pattern, label} ->
      if String.contains?(prompt, pattern) do
        label
      end
    end)
  end

  defp llm_prompt_label(_event), do: nil

  defp ingestion_event?(%{worker: worker}) when is_binary(worker) do
    String.contains?(worker, "Ingestion")
  end

  defp ingestion_event?(_event), do: false

  defp empty_page do
    %{entries: [], page: 1, per_page: @per_page, total_count: 0, total_pages: 1}
  end

  defp refresh_page(socket) do
    push_patch(socket, to: ~p"/admin/jobs")
  end
end
