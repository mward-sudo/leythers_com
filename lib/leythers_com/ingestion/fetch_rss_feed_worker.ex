defmodule LeythersCom.Ingestion.FetchRssFeedWorker do
  @moduledoc """
  Oban worker that fetches RSS/Atom feeds and upserts discovered source entries.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  alias LeythersCom.Ingestion
  alias LeythersCom.Ingestion.HttpClient.Req
  alias LeythersCom.Intelligence

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    attrs = job.args
    process_run_id = Ecto.UUID.generate()

    case Ingestion.ingest_rss_feed(attrs, Req) do
      {:ok, stats} ->
        persist_job_effect_event(job, attrs, stats, nil, process_run_id)
        :ok

      {:error, reason} ->
        persist_job_effect_event(
          job,
          attrs,
          %{processed: 0, inserted: 0, errors: 1},
          inspect(reason),
          process_run_id
        )

        {:error, inspect(reason)}
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

  defp persist_job_effect_event(job, attrs, stats, error_summary, process_run_id) do
    oban_job_id = if is_integer(job.id), do: job.id, else: 0

    worker =
      if is_binary(job.worker),
        do: job.worker,
        else: __MODULE__ |> Module.split() |> Enum.join(".")

    queue = if is_binary(job.queue), do: job.queue, else: "ingestion"
    attempt = if is_integer(job.attempt), do: max(job.attempt, 1), else: 1

    source_ids = Map.get(stats, :new_source_ids, [])
    items = Map.get(stats, :items, [])

    source_input_snapshot = %{
      "feed" => %{
        "url" => Map.get(attrs, "url"),
        "origin_provider" => Map.get(attrs, "origin_provider"),
        "include_keywords" => Map.get(attrs, "include_keywords", [])
      },
      "items" => items
    }

    decision_action = if error_summary, do: "skipped_publish_error", else: "no_op"

    processed = Map.get(stats, :processed, 0)
    inserted = Map.get(stats, :inserted, 0)
    errors = Map.get(stats, :errors, 0)
    seen = max(processed - inserted - errors, 0)

    _ =
      Intelligence.create_job_effect_event(%{
        oban_job_id: oban_job_id,
        worker: worker,
        queue: queue,
        state: if(error_summary, do: "retryable", else: "completed"),
        attempt: attempt,
        decision_action: decision_action,
        process_run_id: process_run_id,
        source_ids: source_ids,
        source_input_snapshot: source_input_snapshot,
        change_summary:
          "#{processed} checked; #{inserted} new; #{seen} already known; #{errors} error(s)",
        change_details: %{
          processed: processed,
          inserted: inserted,
          seen: seen,
          errors: errors
        },
        error_summary: error_summary
      })

    :ok
  end
end
