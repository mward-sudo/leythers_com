defmodule LeythersComWeb.Admin.ArticlePublishLive do
  @moduledoc """
  Admin interface for fast-track manual article publishing.
  """

  use LeythersComWeb, :live_view

  alias LeythersCom.Content

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Manual Article Publish")
     |> assign(:published_slug, nil)
     |> assign(:form, to_form(%{"title" => "", "body" => "", "source_ids" => ""}, as: :article))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-6xl px-4 py-6 sm:px-6 lg:px-8">
        <div class="overflow-hidden rounded-3xl border border-base-300 bg-base-100 shadow-2xl shadow-base-300/20">
          <div class="h-1 bg-gradient-to-r from-primary via-secondary to-accent" />

          <div class="grid gap-0 lg:grid-cols-[minmax(0,1.15fr)_minmax(280px,0.85fr)]">
            <section class="space-y-6 p-6 sm:p-8 lg:p-10">
              <div class="inline-flex items-center gap-2 rounded-full border border-primary/20 bg-primary/10 px-3 py-1 text-xs font-bold uppercase tracking-[0.22em] text-primary">
                Fast-track publish
              </div>

              <div class="space-y-3">
                <h1 class="text-3xl font-semibold tracking-tight sm:text-4xl">
                  Manual Article Publish
                </h1>
                <p class="max-w-2xl text-sm leading-6 text-base-content/70 sm:text-base">
                  Publish a story immediately, with optional source links attached in the same transaction.
                  This path bypasses background jobs and is designed for human-authored updates.
                </p>
              </div>

              <%= if @published_slug do %>
                <div class="alert alert-success items-start border border-success/30 bg-success/10 text-success-content shadow-sm">
                  <.icon name="hero-check-circle" class="mt-0.5 size-5 shrink-0" />
                  <div>
                    <div class="font-semibold">Published article</div>
                    <div class="font-mono text-sm break-all">
                      Published article: {@published_slug}
                    </div>
                  </div>
                </div>
              <% end %>

              <.form
                for={@form}
                id="article-publish-form"
                phx-submit="save"
                class="space-y-5"
              >
                <.input
                  field={@form[:title]}
                  id="article-title"
                  label="Title"
                  class="input input-bordered w-full"
                />
                <.input
                  field={@form[:body]}
                  id="article-body"
                  type="textarea"
                  label="Body"
                  class="textarea textarea-bordered h-44 w-full"
                />
                <.input
                  field={@form[:source_ids]}
                  id="article-source-ids"
                  type="textarea"
                  label="Source IDs"
                  prompt="Optional raw source UUIDs, one per line"
                  class="textarea textarea-bordered h-36 w-full"
                />

                <div class="flex justify-end border-t border-base-300 pt-4">
                  <.button variant="primary" class="btn btn-primary">Publish now</.button>
                </div>
              </.form>
            </section>

            <aside class="border-t border-base-300 bg-base-200/60 p-6 sm:p-8 lg:border-l lg:border-t-0 lg:p-10">
              <h2 class="text-sm font-semibold uppercase tracking-[0.18em] text-base-content/60">
                Publish notes
              </h2>

              <div class="mt-4 space-y-3 text-sm leading-6 text-base-content/75">
                <p class="rounded-2xl bg-base-100 p-4 shadow-sm">
                  <strong class="block text-base-content">Immediate publication</strong>
                  Articles publish immediately and start at version 1.
                </p>

                <p class="rounded-2xl bg-base-100 p-4 shadow-sm">
                  <strong class="block text-base-content">Optional links</strong>
                  Source IDs are optional. If supplied, they are linked in the same database transaction.
                </p>

                <p class="rounded-2xl bg-base-100 p-4 shadow-sm">
                  <strong class="block text-base-content">Deterministic slugs</strong>
                  Slug collisions are resolved deterministically by the content context.
                </p>
              </div>
            </aside>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("save", %{"article" => params}, socket) do
    source_ids = parse_source_ids(params["source_ids"])

    case Content.publish_article(params, source_ids) do
      {:ok, article} ->
        {:noreply,
         socket
         |> assign(:published_slug, article.slug)
         |> assign(
           :form,
           to_form(%{"title" => "", "body" => "", "source_ids" => ""}, as: :article)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
    end
  end

  defp parse_source_ids(nil), do: []

  defp parse_source_ids(source_ids) do
    source_ids
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
