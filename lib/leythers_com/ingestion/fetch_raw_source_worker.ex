defmodule LeythersCom.Ingestion.FetchRawSourceWorker do
  @moduledoc """
  Oban worker that fetches, normalizes, and upserts raw sources.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.HttpClient.Req
  alias LeythersCom.Ingestion.Providers.Basic
  alias LeythersCom.Ingestion.Providers.Html

  @impl Oban.Worker
  def perform(%Oban.Job{args: attrs}) do
    fetch_and_upsert(attrs)
  end

  def fetch_and_upsert(attrs, http_client \\ Req)

  def fetch_and_upsert(%{"html" => _html} = attrs, _http_client) do
    attrs
    |> ensure_external_published_at()
    |> Html.normalize()
    |> Ingestion.upsert_raw_source()

    :ok
  end

  def fetch_and_upsert(%{"url" => url} = attrs, http_client) do
    with {:ok, html} <- http_client.fetch(url) do
      attrs
      |> ensure_external_published_at()
      |> Map.put("html", html)
      |> Html.normalize()
      |> Ingestion.upsert_raw_source()

      :ok
    end
  end

  def fetch_and_upsert(attrs, _http_client) do
    attrs
    |> Basic.normalize()
    |> Ingestion.upsert_raw_source()

    :ok
  end

  defp ensure_external_published_at(attrs) do
    Map.put_new(attrs, "external_published_at", DateTime.utc_now())
  end
end
