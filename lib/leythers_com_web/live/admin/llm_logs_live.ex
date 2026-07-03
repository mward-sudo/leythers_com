defmodule LeythersComWeb.Admin.LLMLogsLive do
  use LeythersComWeb, :live_view

  alias LeythersCom.Intelligence

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "LLM Logs")
     |> assign(:logs_page, empty_page())
     |> assign(:selected_log, nil)
     |> assign(:selected_log_id, nil)
     |> assign(:query_params, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_logs(socket, params)}
  end

  @impl true
  def handle_event("show-log", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: log_path(socket.assigns.logs_page.page, id))}
  end

  @impl true
  def handle_event("clear-log", _params, socket) do
    {:noreply, push_patch(socket, to: page_path(socket.assigns.logs_page.page, nil))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-8" id="llm-logs-page">
        <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h1 class="text-3xl font-semibold tracking-tight">LLM Logs</h1>
            <p class="mt-1 text-sm text-base-content/70">
              Prompt, context, and response history for shared LLM calls.
            </p>
          </div>

          <div class="flex items-center gap-2">
            <.link navigate={~p"/admin/overview"} class="btn btn-outline btn-sm">Overview</.link>
            <.link navigate={~p"/admin/jobs"} class="btn btn-outline btn-sm">Jobs</.link>
          </div>
        </div>

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)]">
          <section
            class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
            id="llm-log-list"
          >
            <div class="mb-4">
              <h2 class="text-lg font-semibold">Recent Calls</h2>
              <p class="text-sm text-base-content/70">
                Page {@logs_page.page} of {@logs_page.total_pages} · {@logs_page.total_count} total
              </p>
            </div>

            <%= if @logs_page.entries == [] do %>
              <div class="rounded-xl border border-dashed border-base-300 px-4 py-10 text-center">
                <p class="text-sm font-medium text-base-content/70">No LLM logs yet</p>
                <p class="mt-1 text-sm text-base-content/55">
                  Calls recorded through the shared LLM client will appear here.
                </p>
              </div>
            <% else %>
              <div class="space-y-3">
                <button
                  :for={log <- @logs_page.entries}
                  id={"llm-log-#{log.id}"}
                  type="button"
                  class={[
                    "w-full rounded-xl border px-4 py-3 text-left transition",
                    @selected_log_id == log.id && "border-primary bg-primary/5",
                    @selected_log_id != log.id &&
                      "border-base-300 bg-base-100 hover:border-base-content/30"
                  ]}
                  phx-click="show-log"
                  phx-value-id={log.id}
                >
                  <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                      <p class="text-sm font-semibold">{log.metadata["purpose"] || "llm_call"}</p>
                      <p class="text-xs text-base-content/60">
                        {log.adapter} · {log.model || "unknown model"}
                      </p>
                    </div>

                    <div class="flex items-center gap-2">
                      <span class={[
                        "badge",
                        log.status == "ok" && "badge-success badge-outline",
                        log.status == "error" && "badge-error badge-outline"
                      ]}>
                        {log.status}
                      </span>
                      <span class="text-xs text-base-content/50">attempt {log.attempt}</span>
                    </div>
                  </div>

                  <p class="mt-3 line-clamp-3 text-sm text-base-content/75">{log.prompt}</p>
                  <p class="mt-2 text-xs text-base-content/50">{format_timestamp(log.inserted_at)}</p>
                </button>
              </div>
            <% end %>

            <div class="mt-5 flex items-center justify-between gap-3">
              <.link
                patch={page_path(max(@logs_page.page - 1, 1), @selected_log_id)}
                class={[
                  "btn btn-outline btn-sm",
                  @logs_page.page <= 1 && "btn-disabled pointer-events-none"
                ]}
              >
                Previous
              </.link>

              <.link
                patch={page_path(min(@logs_page.page + 1, @logs_page.total_pages), @selected_log_id)}
                class={[
                  "btn btn-outline btn-sm",
                  @logs_page.page >= @logs_page.total_pages && "btn-disabled pointer-events-none"
                ]}
              >
                Next
              </.link>
            </div>
          </section>

          <section
            class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
            id="llm-log-detail"
          >
            <%= if @selected_log do %>
              <div class="mb-4 flex items-center justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold">Call Detail</h2>
                  <p class="text-sm text-base-content/65">
                    {format_timestamp(@selected_log.inserted_at)}
                  </p>
                </div>

                <button type="button" class="btn btn-ghost btn-sm" phx-click="clear-log">Clear</button>
              </div>

              <dl class="mb-4 grid gap-3 sm:grid-cols-2">
                <div>
                  <dt class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/50">
                    Purpose
                  </dt>
                  <dd class="mt-1 text-sm">{@selected_log.metadata["purpose"] || "llm_call"}</dd>
                </div>
                <div>
                  <dt class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/50">
                    Status
                  </dt>
                  <dd class="mt-1 text-sm">{@selected_log.status}</dd>
                </div>
                <div>
                  <dt class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/50">
                    Adapter
                  </dt>
                  <dd class="mt-1 break-all text-sm">{@selected_log.adapter}</dd>
                </div>
                <div>
                  <dt class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/50">
                    Model
                  </dt>
                  <dd class="mt-1 text-sm">{@selected_log.model || "unknown model"}</dd>
                </div>
              </dl>

              <div class="space-y-4">
                <section>
                  <h3 class="text-sm font-semibold">Prompt</h3>
                  <pre class="mt-2 max-h-64 overflow-auto rounded-xl border border-base-300 bg-base-200/60 p-3 text-xs"><code>{@selected_log.prompt}</code></pre>
                </section>

                <section>
                  <h3 class="text-sm font-semibold">Context</h3>
                  <pre class="mt-2 max-h-64 overflow-auto rounded-xl border border-base-300 bg-base-200/60 p-3 text-xs"><code>{encode_pretty(@selected_log.context)}</code></pre>
                </section>

                <section>
                  <h3 class="text-sm font-semibold">Metadata</h3>
                  <pre class="mt-2 max-h-40 overflow-auto rounded-xl border border-base-300 bg-base-200/60 p-3 text-xs"><code>{encode_pretty(@selected_log.metadata)}</code></pre>
                </section>

                <section>
                  <h3 class="text-sm font-semibold">Response</h3>
                  <pre class="mt-2 max-h-64 overflow-auto rounded-xl border border-base-300 bg-base-200/60 p-3 text-xs"><code>{@selected_log.response_text || @selected_log.error_summary || "No response body recorded"}</code></pre>
                </section>
              </div>
            <% else %>
              <div class="rounded-xl border border-dashed border-base-300 px-4 py-16 text-center">
                <p class="text-sm font-medium text-base-content/70">Select a log entry</p>
                <p class="mt-1 text-sm text-base-content/55">
                  Prompt, context, metadata, and response details will appear here.
                </p>
              </div>
            <% end %>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_logs(socket, params) do
    page = parse_positive_int(params["page"], 1)
    logs_page = Intelligence.list_llm_interaction_logs(%{page: page, per_page: @per_page})
    selected_log_id = params["id"]

    selected_log =
      case selected_log_id do
        nil -> nil
        "" -> nil
        id -> Intelligence.get_llm_interaction_log(id)
      end

    query_params =
      params
      |> Map.take(["page", "id"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    socket
    |> assign(:logs_page, logs_page)
    |> assign(:selected_log, selected_log)
    |> assign(:selected_log_id, selected_log_id)
    |> assign(:query_params, query_params)
  end

  defp page_path(page, nil), do: ~p"/admin/llm-logs?page=#{page}"
  defp page_path(page, id), do: ~p"/admin/llm-logs?page=#{page}&id=#{id}"
  defp log_path(page, id), do: ~p"/admin/llm-logs?page=#{page}&id=#{id}"

  defp parse_positive_int(nil, default), do: default

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default

  defp empty_page do
    %{entries: [], page: 1, per_page: @per_page, total_count: 0, total_pages: 1}
  end

  defp format_timestamp(nil), do: "unknown time"

  defp format_timestamp(%DateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp encode_pretty(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(value, pretty: true, limit: :infinity)
    end
  end
end
