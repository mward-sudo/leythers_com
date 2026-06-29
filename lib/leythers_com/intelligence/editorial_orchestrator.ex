defmodule LeythersCom.Intelligence.EditorialOrchestrator do
  @moduledoc """
  Coordinates source-update-triggered homepage ranking refreshes,
  persists ranking decision snapshots, and enforces refresh cooldowns.
  """

  import Ecto.Query

  alias LeythersCom.Content
  alias LeythersCom.Intelligence.HomepageRanker
  alias LeythersCom.Intelligence.HomepageRankingDecision
  alias LeythersCom.Repo

  @trigger_cache_table :leythers_com_editorial_orchestration_trigger_cache

  @default_config [
    source_limit: 20,
    homepage_size: 12,
    refresh_cooldown_seconds: 300,
    async_source_refresh: true,
    prompt_version: "homepage_ranker_v1"
  ]

  def refresh_homepage_layout(opts \\ []) do
    started_at = System.monotonic_time()
    config = config() |> Keyword.merge(opts)

    ranking_opts =
      opts
      |> Keyword.drop([:source_limit, :homepage_size, :refresh_cooldown_seconds, :prompt_version])

    ranked_entries =
      config[:source_limit]
      |> Content.list_recent_articles_with_sources()
      |> HomepageRanker.rank(ranking_opts)
      |> Enum.take(config[:homepage_size])

    run_id = Ecto.UUID.generate()

    result =
      Repo.transaction(fn ->
        ranked_entries
        |> Enum.with_index(1)
        |> Enum.each(fn {entry, rank_position} ->
          attrs =
            decision_attrs(
              run_id,
              entry,
              rank_position,
              config[:prompt_version]
            )

          %HomepageRankingDecision{}
          |> HomepageRankingDecision.changeset(attrs)
          |> Repo.insert!()
        end)
      end)

    finalized_result =
      case result do
        {:ok, _} ->
          {:ok,
           %{
             run_id: run_id,
             ranked_entries: ranked_entries,
             decision_count: length(ranked_entries)
           }}

        {:error, reason} ->
          {:error, reason}
      end

    emit_refresh_telemetry(
      finalized_result,
      started_at,
      Keyword.get(opts, :triggered_by, :manual)
    )

    finalized_result
  end

  def latest_homepage_snapshot(limit \\ 12)

  def latest_homepage_snapshot(limit) when is_integer(limit) and limit > 0 do
    case latest_run_id() do
      nil ->
        []

      run_id ->
        HomepageRankingDecision
        |> where([decision], decision.run_id == ^run_id)
        |> join(:inner, [decision], article in assoc(decision, :permanent_article))
        |> order_by([decision, _article], asc: decision.rank_position)
        |> limit(^limit)
        |> select([decision, article], %{
          article: article,
          source_count: decision.source_count,
          recency_score: decision.recency_score,
          importance_score: decision.importance_score,
          importance_source: decision.importance_source,
          hybrid_score: decision.hybrid_score
        })
        |> Repo.all()
        |> Enum.map(fn entry ->
          entry
          |> Map.put(:sources, List.duplicate(%{}, entry.source_count))
          |> Map.delete(:source_count)
        end)
    end
  end

  def latest_homepage_snapshot(_limit), do: []

  def trigger_source_update_refresh(opts \\ []) do
    config = config() |> Keyword.merge(opts)
    ensure_trigger_cache_table!()

    now = System.system_time(:second)
    cooldown_seconds = config[:refresh_cooldown_seconds]
    async_refresh? = Keyword.get(opts, :async, config[:async_source_refresh])

    case last_refresh_at() do
      {:ok, last_run_at} ->
        if now - last_run_at < cooldown_seconds do
          {:ok, :cooldown}
        else
          maybe_run_refresh(now, opts, async_refresh?)
        end

      _ ->
        maybe_run_refresh(now, opts, async_refresh?)
    end
  end

  def clear_trigger_cache! do
    ensure_trigger_cache_table!()
    :ets.delete_all_objects(@trigger_cache_table)
    :ok
  end

  defp maybe_run_refresh(now, opts, true) do
    if refresh_in_progress?() do
      {:ok, :in_progress}
    else
      mark_refresh_started(now)

      Task.start(fn ->
        try do
          _ = refresh_homepage_layout(Keyword.put(opts, :triggered_by, :source_update))
        after
          mark_refresh_finished()
        end
      end)

      {:ok, :queued}
    end
  end

  defp maybe_run_refresh(now, opts, false) do
    if refresh_in_progress?() do
      {:ok, :in_progress}
    else
      mark_refresh_started(now)

      try do
        refresh_homepage_layout(Keyword.put(opts, :triggered_by, :source_update))
      after
        mark_refresh_finished()
      end
    end
  end

  defp latest_run_id do
    HomepageRankingDecision
    |> order_by([decision], desc: decision.inserted_at)
    |> limit(1)
    |> select([decision], decision.run_id)
    |> Repo.one()
  end

  defp decision_attrs(run_id, entry, rank_position, prompt_version) do
    %{
      run_id: run_id,
      permanent_article_id: entry.article.id,
      rank_position: rank_position,
      hybrid_score: entry.hybrid_score,
      importance_score: entry.importance_score,
      recency_score: entry.recency_score,
      importance_source: normalize_importance_source(entry.importance_source),
      source_count: length(entry.sources),
      prompt_version: prompt_version,
      decision_summary: decision_summary(entry),
      input_tokens: 0,
      output_tokens: 0,
      estimated_cost_gbp: Decimal.new("0")
    }
  end

  defp decision_summary(entry) do
    "hybrid score #{entry.hybrid_score} from recency #{entry.recency_score} and importance #{entry.importance_score}"
  end

  defp normalize_importance_source(source) when source in [:llm_generated, "llm_generated"],
    do: "llm_generated"

  defp normalize_importance_source(source) when source in [:llm_cached, "llm_cached"],
    do: "llm_cached"

  defp normalize_importance_source(_source), do: "deterministic"

  defp emit_refresh_telemetry(result, started_at, triggered_by) do
    metadata =
      case result do
        {:ok, %{decision_count: decision_count}} ->
          %{result: :ok, decision_count: decision_count, triggered_by: triggered_by}

        {:error, _reason} ->
          %{result: :error, decision_count: 0, triggered_by: triggered_by}
      end

    :telemetry.execute(
      [:leythers_com, :intelligence, :editorial_orchestration, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      metadata
    )
  end

  defp ensure_trigger_cache_table! do
    case :ets.whereis(@trigger_cache_table) do
      :undefined ->
        :ets.new(@trigger_cache_table, [:set, :public, :named_table, read_concurrency: true])

      _tid ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp last_refresh_at do
    case :ets.lookup(@trigger_cache_table, :last_refresh_at) do
      [{:last_refresh_at, last_run_at}] -> {:ok, last_run_at}
      _ -> :error
    end
  end

  defp refresh_in_progress? do
    case :ets.lookup(@trigger_cache_table, :refresh_in_progress) do
      [{:refresh_in_progress, true}] -> true
      _ -> false
    end
  end

  defp mark_refresh_started(now) do
    ensure_trigger_cache_table!()
    :ets.insert(@trigger_cache_table, {:last_refresh_at, now})
    :ets.insert(@trigger_cache_table, {:refresh_in_progress, true})
  end

  defp mark_refresh_finished do
    ensure_trigger_cache_table!()
    :ets.insert(@trigger_cache_table, {:refresh_in_progress, false})
  end

  defp config do
    Application.get_env(:leythers_com, :editorial_orchestration, @default_config)
    |> Keyword.merge(@default_config, fn _key, left, _right -> left end)
  end
end
