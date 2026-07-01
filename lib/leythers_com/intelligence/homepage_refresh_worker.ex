defmodule LeythersCom.Intelligence.HomepageRefreshWorker do
  @moduledoc """
  Oban worker that executes homepage refresh orchestration in a supervised OTP flow.
  """

  use Oban.Worker, queue: :intelligence, max_attempts: 200

  alias LeythersCom.Intelligence.EditorialOrchestrator

  @default_retry_base_seconds 1
  @default_retry_max_seconds 15
  @default_retry_persist_threshold 3

  def enqueue(attrs \\ []) when is_list(attrs) do
    args =
      attrs
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)

    args
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    EditorialOrchestrator.run_source_update_refresh(args)
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{} = job) do
    base_seconds = retry_base_seconds() |> max(1)
    max_seconds = retry_max_seconds() |> max(base_seconds)
    attempt = max(job.attempt, 1)
    persist_threshold = retry_persist_threshold() |> max(1)

    delay_seconds =
      if attempt <= persist_threshold do
        base_seconds
      else
        escalation_attempt = attempt - persist_threshold
        base_seconds * trunc(:math.pow(2, escalation_attempt - 1))
      end

    min(delay_seconds, max_seconds)
  end

  defp retry_base_seconds do
    :leythers_com
    |> Application.get_env(:editorial_orchestration, [])
    |> Keyword.get(:refresh_retry_base_seconds, @default_retry_base_seconds)
  end

  defp retry_max_seconds do
    :leythers_com
    |> Application.get_env(:editorial_orchestration, [])
    |> Keyword.get(:refresh_retry_max_seconds, @default_retry_max_seconds)
  end

  defp retry_persist_threshold do
    :leythers_com
    |> Application.get_env(:editorial_orchestration, [])
    |> Keyword.get(:refresh_retry_persist_threshold, @default_retry_persist_threshold)
  end
end
