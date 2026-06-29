defmodule LeythersComWeb.Admin.ArticlePublishLive do
  @moduledoc """
  Admin interface for fast-track manual article publishing.
  """

  use LeythersComWeb, :live_view

  import Ecto.Changeset

  alias Ecto.UUID
  alias LeythersCom.Content

  @article_form_types %{title: :string, body: :string, source_ids: :string}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Manual Article Publish")
     |> assign(:published_slug, nil)
     |> assign(:form, article_form(%{"title" => "", "body" => "", "source_ids" => ""}))
     |> assign(:cleanup_form, to_form(%{"slug_prefix" => "smoke-test-"}, as: :cleanup))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl px-4 py-6 sm:px-6 lg:px-8">
        <div class="mb-4 flex justify-end">
          <.link navigate={~p"/admin/overview"} class="btn btn-outline btn-sm">
            View Admin Overview
          </.link>
        </div>

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
                phx-change="validate"
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
                  <.button
                    variant="primary"
                    class="btn btn-primary"
                    phx-disable-with="Publishing..."
                  >
                    Publish now
                  </.button>
                </div>

                <p class="hidden text-sm text-base-content/70 phx-submit-loading:block" role="status">
                  Publishing article...
                </p>
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

                <.form
                  for={@cleanup_form}
                  id="article-cleanup-form"
                  phx-submit="cleanup"
                  class="space-y-3 rounded-2xl border border-warning/30 bg-warning/10 p-4"
                >
                  <p class="text-sm">
                    <strong class="block text-base-content">Cleanup tool</strong>
                    Delete previously created smoke-test articles by slug prefix.
                  </p>

                  <.input
                    field={@cleanup_form[:slug_prefix]}
                    id="cleanup-slug-prefix"
                    label="Slug prefix"
                    class="input input-bordered w-full"
                  />

                  <.button class="btn btn-warning" phx-disable-with="Deleting...">
                    Delete matching articles
                  </.button>
                </.form>
              </div>
            </aside>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"article" => params}, socket) do
    {:noreply, assign(socket, :form, article_form(params, action: :validate))}
  end

  @impl true
  def handle_event("save", %{"article" => params}, socket) do
    form_changeset = article_changeset(params)

    if form_changeset.valid? do
      source_ids = parse_source_ids(params["source_ids"])

      case Content.publish_article(params, source_ids) do
        {:ok, article} ->
          {:noreply,
           socket
           |> put_flash(:info, "Article published successfully")
           |> assign(:published_slug, article.slug)
           |> assign(:form, article_form(%{"title" => "", "body" => "", "source_ids" => ""}))}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Unable to publish article")
           |> assign(:form, article_form_with_publish_error(form_changeset, changeset))}
      end
    else
      {:noreply, assign(socket, :form, article_form(params, action: :validate))}
    end
  end

  @impl true
  def handle_event("cleanup", %{"cleanup" => %{"slug_prefix" => slug_prefix}}, socket) do
    case Content.delete_articles_by_slug_prefix(slug_prefix) do
      {:ok, deleted_count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{deleted_count} matching article(s)")
         |> assign(:cleanup_form, to_form(%{"slug_prefix" => slug_prefix}, as: :cleanup))}

      {:error, :invalid_prefix} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please provide a non-empty slug prefix")
         |> assign(:cleanup_form, to_form(%{"slug_prefix" => slug_prefix}, as: :cleanup))}
    end
  end

  defp article_form(params, opts \\ []) do
    params
    |> article_changeset()
    |> maybe_set_action(opts[:action])
    |> to_form(as: :article)
  end

  defp article_changeset(params) do
    {%{}, @article_form_types}
    |> cast(params, Map.keys(@article_form_types))
    |> validate_required([:title, :body])
    |> validate_change(:source_ids, fn :source_ids, source_ids ->
      if invalid_source_ids?(source_ids) do
        [source_ids: "must contain valid UUIDs separated by commas or new lines"]
      else
        []
      end
    end)
  end

  defp article_form_with_publish_error(form_changeset, publish_changeset) do
    changeset =
      if Keyword.has_key?(publish_changeset.errors, :raw_source_id) do
        add_error(form_changeset, :source_ids, "contains unknown source IDs")
      else
        form_changeset
      end

    changeset
    |> maybe_set_action(:validate)
    |> to_form(as: :article)
  end

  defp maybe_set_action(changeset, nil), do: changeset
  defp maybe_set_action(changeset, action), do: %{changeset | action: action}

  defp invalid_source_ids?(nil), do: false

  defp invalid_source_ids?(source_ids) do
    source_ids
    |> parse_source_ids()
    |> Enum.any?(&(UUID.cast(&1) == :error))
  end

  defp parse_source_ids(nil), do: []

  defp parse_source_ids(source_ids) do
    source_ids
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
