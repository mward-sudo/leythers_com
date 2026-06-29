defmodule LeythersCom.Ingestion.FetchRssFeedWorker do
  @moduledoc """
  Oban worker that fetches RSS/Atom feeds and upserts discovered source entries.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.HttpClient.Req

  @impl Oban.Worker
  def perform(%Oban.Job{args: attrs}) do
    case Ingestion.ingest_rss_feed(attrs, Req) do
      {:ok, _stats} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
