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
      <div class="manual-publish-page">
        <div class="manual-publish-shell">
          <div class="manual-publish-grid">
            <section class="manual-publish-main">
              <div class="manual-publish-kicker">Fast-track publish</div>
              <h1 class="manual-publish-title">Manual Article Publish</h1>
              <p class="manual-publish-lede">
                Publish a story immediately, with optional source links attached in the same transaction.
                This path bypasses background jobs and is designed for human-authored updates.
              </p>

              <%= if @published_slug do %>
                <div class="manual-publish-status published-banner">
                  <div>
                    <strong>Published article</strong>
                    <div class="manual-publish-slug">Published article: {@published_slug}</div>
                  </div>
                </div>
              <% end %>

              <.form
                for={@form}
                id="article-publish-form"
                phx-submit="save"
                class="manual-publish-form"
              >
                <.input field={@form[:title]} id="article-title" label="Title" />
                <.input field={@form[:body]} id="article-body" type="textarea" label="Body" />
                <.input
                  field={@form[:source_ids]}
                  id="article-source-ids"
                  type="textarea"
                  label="Source IDs"
                  prompt="Optional raw source UUIDs, one per line"
                />

                <div class="manual-publish-submit">
                  <.button variant="primary" class="manual-publish-button">Publish now</.button>
                </div>
              </.form>
            </section>

            <aside class="manual-publish-aside manual-publish-sidebar">
              <h2>Publish notes</h2>

              <p class="manual-publish-note">
                <strong>Immediate publication</strong>
                Articles publish immediately and start at version 1.
              </p>

              <p class="manual-publish-note">
                <strong>Optional links</strong>
                Source IDs are optional. If supplied, they are linked in the same database transaction.
              </p>

              <p class="manual-publish-note">
                <strong>Deterministic slugs</strong>
                Slug collisions are resolved deterministically by the content context.
              </p>
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
