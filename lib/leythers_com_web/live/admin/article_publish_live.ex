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
      <div class="space-y-6">
        <div class="space-y-2">
          <h1 class="text-2xl font-semibold tracking-tight">Manual Article Publish</h1>
          <p class="text-sm text-base-content/70">
            Publish a story immediately, with optional source links attached in the same transaction.
          </p>
        </div>

        <%= if @published_slug do %>
          <div class="rounded-lg border border-success/30 bg-success/10 p-4 text-success-content">
            Published article: {@published_slug}
          </div>
        <% end %>

        <.form for={@form} id="article-publish-form" phx-submit="save" class="space-y-4">
          <.input field={@form[:title]} id="article-title" label="Title" />
          <.input field={@form[:body]} id="article-body" type="textarea" label="Body" />
          <.input
            field={@form[:source_ids]}
            id="article-source-ids"
            type="textarea"
            label="Source IDs"
            prompt="Optional raw source UUIDs, one per line"
          />

          <div class="flex justify-end">
            <.button variant="primary">Publish now</.button>
          </div>
        </.form>
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
