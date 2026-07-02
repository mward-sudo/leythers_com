defmodule LeythersCom.Ingestion.FetchSourceContentWorker do
  @moduledoc """
  Oban worker that fetches full content for an existing raw source.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  alias LeythersCom.Ingestion

  @enqueue_unique_seconds 3_600

  def enqueue(source_id) when is_binary(source_id) do
    %{"source_id" => source_id}
    |> new(
      unique: [
        fields: [:worker, :args],
        period: @enqueue_unique_seconds,
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) when is_binary(source_id) do
    _ = Ingestion.fetch_and_store_content(source_id)
    :ok
  end

  @impl Oban.Worker
  def perform(_job), do: :ok
end
