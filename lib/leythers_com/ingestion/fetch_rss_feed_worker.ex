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

  @impl Oban.Worker
  def backoff(%Oban.Job{} = job) do
    base_seconds =
      retry_base_seconds()
      |> max(1)

    max_seconds =
      retry_max_seconds()
      |> max(base_seconds)

    attempt = max(job.attempt, 1)

    provider_multiplier =
      job.args
      |> Map.get("origin_provider")
      |> retry_multiplier_for_provider()

    base_delay = trunc(base_seconds * :math.pow(2, attempt - 1))

    base_delay
    |> Kernel.*(provider_multiplier)
    |> trunc()
    |> min(max_seconds)
  end

  defp retry_base_seconds do
    :leythers_com
    |> Application.get_env(:ingestion_monitoring, [])
    |> Keyword.get(:retry_base_seconds, 60)
  end

  defp retry_max_seconds do
    :leythers_com
    |> Application.get_env(:ingestion_monitoring, [])
    |> Keyword.get(:retry_max_seconds, 1800)
  end

  defp retry_multiplier_for_provider(nil), do: 1.0

  defp retry_multiplier_for_provider(origin_provider) do
    :leythers_com
    |> Application.get_env(:ingestion_monitoring, [])
    |> Keyword.get(:retry_multipliers, %{})
    |> Map.get(origin_provider, 1.0)
    |> normalize_multiplier()
  end

  defp normalize_multiplier(value) when is_integer(value) and value > 0, do: value / 1
  defp normalize_multiplier(value) when is_float(value) and value > 0.0, do: value
  defp normalize_multiplier(_), do: 1.0
end
