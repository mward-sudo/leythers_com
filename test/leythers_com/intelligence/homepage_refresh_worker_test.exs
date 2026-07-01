defmodule LeythersCom.Intelligence.HomepageRefreshWorkerTest do
  @moduledoc false
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Intelligence.HomepageRefreshWorker

  setup do
    original_config = Application.get_env(:leythers_com, :editorial_orchestration)

    on_exit(fn ->
      Application.put_env(:leythers_com, :editorial_orchestration, original_config)
    end)

    :ok
  end

  test "extends backoff only after persistent refresh errors" do
    Application.put_env(:leythers_com, :editorial_orchestration,
      source_limit: 20,
      homepage_size: 12,
      refresh_cooldown_seconds: 300,
      refresh_retry_base_seconds: 1,
      refresh_retry_max_seconds: 8,
      refresh_retry_persist_threshold: 3,
      async_source_refresh: true,
      prompt_version: "homepage_ranker_v1"
    )

    assert HomepageRefreshWorker.backoff(%Oban.Job{attempt: 1, args: %{}}) == 1
    assert HomepageRefreshWorker.backoff(%Oban.Job{attempt: 2, args: %{}}) == 1
    assert HomepageRefreshWorker.backoff(%Oban.Job{attempt: 3, args: %{}}) == 1
    assert HomepageRefreshWorker.backoff(%Oban.Job{attempt: 4, args: %{}}) == 1
    assert HomepageRefreshWorker.backoff(%Oban.Job{attempt: 5, args: %{}}) == 2
    assert HomepageRefreshWorker.backoff(%Oban.Job{attempt: 6, args: %{}}) == 4
    assert HomepageRefreshWorker.backoff(%Oban.Job{attempt: 7, args: %{}}) == 8
    assert HomepageRefreshWorker.backoff(%Oban.Job{attempt: 8, args: %{}}) == 8
  end
end
