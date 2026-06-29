defmodule LeythersCom.Ingestion.FetchRawSourceWorker do
  @moduledoc """
  Oban worker that normalizes source payloads and upserts raw sources.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.Providers.Basic
  alias LeythersCom.Ingestion.Providers.Html

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"html" => _html} = attrs}) do
    attrs
    |> Html.normalize()
    |> Ingestion.upsert_raw_source()

    :ok
  end

  def perform(%Oban.Job{args: attrs}) do
    attrs
    |> Basic.normalize()
    |> Ingestion.upsert_raw_source()

    :ok
  end
end
